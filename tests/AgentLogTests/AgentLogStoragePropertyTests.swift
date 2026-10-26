@testable import Core
@testable import Inbound
@testable import Storage
import Foundation
import XCTest

private final class LogPropertyDatabase {
  let base: URL
  var storage: ActivityStorage!
  init(_ root: URL) throws {
    base = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try reopen()
    try storage.saveSettings(StorageSettings(), at: 0)
  }
  func reopen() throws {
    storage = nil
    storage = try ActivityStorage(url: base.appendingPathComponent("invented.sqlite"),
      appDataDirectory: base, databaseScope: .directory(base))
  }
  deinit { storage = nil; try? FileManager.default.removeItem(at: base) }
  func position(_ source: Int, tool: AgentLogTool = .claude, session: String? = nil, seen: Int = 500) throws -> LogPosition {
    var state = AgentLogState(); state.tool = tool.rawValue
    state.session = session.flatMap { AgentLogIdentity.decoded($0).session.subject }
    return LogPosition(path: base.appendingPathComponent("invented-\(source).jsonl").path,
      device: 71, inode: source, offset: 1000, state: try state.encoded(), seenAt: seen)
  }
}

extension AgentLogTests {
  private func propertyEvent(_ raw: String, alias: String? = nil, session: String = "invented-foreign",
    role: String = "user", tool: AgentLogTool = .claude, time: Int = 200, offset: Int = 0) throws -> AgentLogEvent {
    let fields: [String: Any]
    if tool == .claude {
      var record: [String: Any] = ["type": role, "sessionId": session, "uuid": raw,
        "timestamp": stamp(time), "message": ["content": "Invented property instruction"]]
      if let alias { record["commandUuid"] = alias }
      fields = record
    } else {
      let kind = ["user": "UserMessage", "assistant": "AssistantMessage", "tool": "ToolResult", "system": "Unknown"][role]!
      fields = ["type": "event_msg", "timestamp": stamp(time), "payload": ["type": "item_completed",
        "thread_id": session, "turn_id": "invented-turn", "item": ["id": raw, "type": kind,
          "content": [["type": "text", "text": "Invented property instruction"]]]]]
    }
    let text = try json(fields)
    var state = AgentLogState()
    return try XCTUnwrap(AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count, offset: offset,
      observedAt: 500, tool: tool, file: "/invented/property.jsonl", state: &state, logsRelativePath: nil,
      fingerprint: AgentLogFiles.fingerprint))
  }
  private func propertyCommit(_ event: AgentLogEvent, _ database: LogPropertyDatabase, source: Int,
    seen: Int = 500) throws {
    try database.storage.appendLogEvents([event], evidence: event.prompt.map { [$0] } ?? [],
      position: database.position(source, tool: event.tool, seen: seen))
  }

  func testGeneratedExplicitEdgesSurviveOrderingAndPrivacyClosure() throws {
    struct Edge: CustomStringConvertible {
      let from: Int, to: Int, role: Int, reopen: Bool
      var description: String { "\(from)>\(to)/role\(role)/reopen\(reopen)" }
    }
    let raw = ["invented-é", "invented-e\u{301}", "invented-a", "invented-b", "invented-c"]
    let bytes = raw.map { Data(("claude:" + $0).utf8) }
    let pairs = [(0, 1), (0, 2), (2, 3), (3, 4), (4, 0), (1, 3)]
    for seed in logPropertySeeds {
      var random = LogTraceRandom(state: seed)
      let trace = random.shuffle(pairs).map { Edge(from: $0.0, to: $0.1, role: random.next(4), reopen: random.next(2) == 0) }
      try checkLogTrace(seed: seed, trace: trace) { edges in
        let db = try LogPropertyDatabase(self.root)
        let initial = try self.propertyEvent(raw[0], time: 50)
        try self.propertyCommit(initial, db, source: 1)
        let range = TimeRange(50, 51)
        try db.storage.deleteRecords(in: range, confirmation: db.storage.previewDeletion(in: range).confirmation)
        var model = LogByteModel(); model.refuse(bytes[0])
        var observed: [Edge] = []
        for (index, edge) in edges.enumerated() {
          model.link(bytes[edge.from], bytes[edge.to]); model.seal()
          let event = try self.propertyEvent(raw[edge.from], alias: raw[edge.to],
            role: ["user", "assistant", "tool", "system"][edge.role], time: 200 + index)
          try self.propertyCommit(event, db, source: 10 + index)
          observed.append(edge)
          for seen in observed {
            if try db.storage.connection.integer("SELECT count(*) FROM agent_prompt_edges WHERE alias=? AND canonical=?",
              [.key("claude:" + raw[seen.from]), .key("claude:" + raw[seen.to])]) != 1 { return "observed edge was lost" }
          }
          let admitted = try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=?", [.integer(10 + index)])
          if admitted != (model.allows(bytes[edge.from]) ? 1 : 0) { return "event refusal differs from byte graph" }
          if !model.allows(bytes[edge.from]),
            try db.storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=?", [.integer(200 + index)]) != 0 { return "forbidden projection escaped graph closure" }
          for node in raw.indices {
            try db.storage.resolveLogIdentities([AgentLogIdentityCodec.instruction("claude:" + raw[node])])
            var actual = Set<Data>()
            try db.storage.connection.namedRows("SELECT identity FROM log_identity_component") { actual.insert(Data(try $0.text("identity").utf8)) }
            if actual != model.closure([bytes[node]]) { return "closure differs from byte reference graph" }
          }
          if edge.reopen { try db.reopen() }
        }
        return nil
      }
    }
  }

  func testGeneratedPositiveOwnershipAffectsOnlyProvenSubjectsAndSources() throws {
    struct Step: CustomStringConvertible {
      let tool: AgentLogTool, role: Int, timing: Int, restart: Bool
      var description: String { "\(tool)/role\(role)/receipt\(timing)/restart\(restart)" }
    }
    for seed in logPropertySeeds {
      var random = LogTraceRandom(state: seed)
      let trace = random.shuffle(AgentLogTool.allCases.flatMap { tool in (0..<3).map {
        Step(tool: tool, role: random.next(4), timing: $0, restart: random.next(2) == 0)
      } })
      try checkLogTrace(seed: seed, trace: trace) { steps in
        for step in steps {
          let db = try LogPropertyDatabase(self.root)
          let own = "invented-é", foreign = "invented-e\u{301}"
          let registry = AgentLogFiles.ownSources(appDataDirectory: db.base)
          // Equal native content proves no ownership. The foreign creator must survive own-copy revocation.
          let original = try self.propertyEvent("invented-shared", session: foreign, tool: step.tool, time: 50)
          try self.propertyCommit(original, db, source: 1)
          if step.timing == 0 { try registry.registerSession(own, tool: step.tool) }
          let event = try self.propertyEvent("invented-shared", session: own,
            role: ["user", "assistant", "tool", "system"][step.role], tool: step.tool)
          if step.timing == 1 { try registry.registerSession(own, tool: step.tool) }
          try self.propertyCommit(event, db, source: 2)
          if step.timing == 2 { try registry.registerSession(own, tool: step.tool) }
          if step.restart { try db.reopen() }
          try db.storage.appendLogEvents([], evidence: [], position: db.position(2, tool: step.tool, session: own))
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=2") != 0 { return "proven own source survived" }
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=1") != 1 { return "byte-distinct foreign source revoked" }
          if try db.storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=50") != 1 { return "foreign canonical creator was erased" }
          if try registry.containsSession(foreign, tool: step.tool) { return "foreign subject promoted to ownership" }
          let future = try self.propertyEvent("invented-future", session: foreign, tool: step.tool, time: 300)
          try self.propertyCommit(future, db, source: 3)
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=3") != 1 { return "future foreign source refused" }
        }
        return nil
      }
    }
  }

  func testGeneratedForgetOffPauseAreMonotoneButRetentionIsNot() throws {
    struct Step: CustomStringConvertible {
      let barrier: Int, role: Int, restart: Bool
      var description: String { "barrier\(barrier)/role\(role)/restart\(restart)" }
    }
    for seed in logPropertySeeds {
      var random = LogTraceRandom(state: seed)
      let trace = random.shuffle((0..<4).flatMap { barrier in (0..<4).map {
        Step(barrier: barrier, role: $0, restart: random.next(2) == 0)
      } })
      try checkLogTrace(seed: seed, trace: trace) { steps in
        for step in steps {
          let db = try LogPropertyDatabase(self.root)
          var model = LogByteModel()
          let root = Data("claude:invented-root".utf8), copy = Data("claude:invented-copy".utf8)
          let event = try self.propertyEvent("invented-root", time: 100)
          if step.barrier == 1 { try db.storage.saveSettings(StorageSettings(recordingEnabled: false), at: 90) }
          if step.barrier == 2 { try db.storage.saveSettings(StorageSettings(pausedUntil: 150), at: 90) }
          try self.propertyCommit(event, db, source: 1, seen: 110)
          if step.barrier == 0 {
            let range = TimeRange(100, 101)
            try db.storage.deleteRecords(in: range, confirmation: db.storage.previewDeletion(in: range).confirmation)
          }
          if step.barrier == 3 {
            try db.storage.saveSettings(StorageSettings(promptRetentionDays: 1), at: 120)
            try db.storage.cleanRetention(at: 200_000)
          } else { model.refuse(root) }
          try db.storage.saveSettings(StorageSettings(promptRetentionDays: 30), at: 200_001)
          if step.restart { try db.reopen() }
          model.link(root, copy); model.seal()
          let future = try self.propertyEvent("invented-copy", alias: "invented-root",
            role: ["user", "assistant", "tool", "system"][step.role], time: 200_002)
          try self.propertyCommit(future, db, source: 2, seen: 200_010)
          let allowed = model.allows(copy)
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=2") != (allowed ? 1 : 0) { return "permanent/expiry policy differs from byte model" }
          if !allowed, try db.storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=200002") != 0 { return "forbidden projection escaped" }
          // Increasing retention and explicit replay can readmit expired material, even its old timestamp.
          let replay = try self.propertyEvent("invented-root", time: 100)
          try self.propertyCommit(replay, db, source: 3, seen: 200_010)
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events WHERE inode=3") != (allowed ? 1 : 0) { return "copy/reopen changed refusal or retention became permanent" }
        }
        return nil
      }
    }
  }

  func testGeneratedTransactionAbortsRollBackEventsProjectionRefusalsAndCursor() throws {
    struct Step: CustomStringConvertible {
      let table: String, role: Int, restart: Bool
      var description: String { "abort=\(table)/role\(role)/restart\(restart)" }
    }
    let tables = ["agent_log_payloads", "agent_log_events", "evidence", "log_positions"]
    let snapshotTables = tables + ["agent_prompt_edges", "agent_log_refusals", "forgotten_sources",
      "agent_log_event_identities", "agent_log_source_evidence", "agent_log_evidence_origins", "agent_log_own_baseline_runs"]
    for seed in logPropertySeeds {
      var random = LogTraceRandom(state: seed)
      let trace = random.shuffle(tables).map { Step(table: $0, role: random.next(4), restart: random.next(2) == 0) }
      try checkLogTrace(seed: seed, trace: trace) { steps in
        for step in steps {
          let db = try LogPropertyDatabase(self.root)
          try db.storage.saveSettings(StorageSettings(recordingEnabled: false), at: 90)
          try db.storage.saveSettings(StorageSettings(), at: 150)
          let forbidden = try self.propertyEvent("invented-forbidden", alias: "invented-forbidden-root",
            role: ["user", "assistant", "tool", "system"][step.role], time: 100)
          let allowed = try self.propertyEvent("invented-allowed", alias: "invented-allowed-root", time: 200, offset: 100)
          let events = [forbidden, allowed], projections = events.compactMap(\.prompt)
          let position = try db.position(1)
          let before = try snapshotTables.map { try db.storage.connection.integer("SELECT count(*) FROM \($0)") }
          try db.storage.connection.run("CREATE TRIGGER invented_abort BEFORE INSERT ON \(step.table) BEGIN SELECT RAISE(ABORT,'invented abort'); END")
          var aborted = false
          do { try db.storage.appendLogEvents(events, evidence: projections, position: position) }
          catch { aborted = true }
          if !aborted { return "injected transaction abort did not fire" }
          let after = try snapshotTables.map { try db.storage.connection.integer("SELECT count(*) FROM \($0)") }
          if before != after { return "transaction leaked partial event/projection/refusal/cursor effects at \(step.table)" }
          try db.storage.connection.run("DROP TRIGGER invented_abort")
          if step.restart { try db.reopen() }
          try db.storage.appendLogEvents(events, evidence: projections, position: position)
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_events") != 1 { return "retry event effects disagree with model" }
          if try db.storage.connection.integer("SELECT count(*) FROM evidence") != 1 { return "forbidden projection escaped retry" }
          if try db.storage.connection.integer("SELECT count(*) FROM evidence WHERE ts=100") != 0 { return "forbidden content persisted" }
          if try db.storage.logPosition(path: position.path)?.offset != 1000 { return "cursor not committed with content" }
          if try db.storage.connection.integer("SELECT count(*) FROM agent_log_refusals") != 1 { return "refusal not committed with content" }
        }
        return nil
      }
    }
  }
}
