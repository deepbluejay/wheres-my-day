import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension AgentLogTests {
  private func importInvented(_ fields: [String: Any], name: String, at time: Int) throws -> AgentLogBatch {
    let url = try file(.claude, name: name + ".jsonl")
    try write([json(fields)], to: url)
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    let batch = try AgentLogFiles.read(source, tool: .claude, position: nil, at: time)
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    return batch
  }
  func testEscapedCredentialsInEveryAcquiredStringUseOneRepresentation() throws {
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let escaped = secret.map { String(format: "\\u%04x", $0.asciiValue!) }.joined()
    let nestedEscaped = escaped.replacingOccurrences(of: "\\", with: "\\u005c")
    let fields: [String: Any] = ["type": "user", "timestamp": stamp(100), "sessionId": escaped,
      "cwd": "/invented/" + escaped, "uuid": escaped, "commandUuid": "alias-" + escaped,
      "source_uuid": "source-" + escaped,
      "message": ["role": escaped, "content": "Invented prompt"],
      "origin": ["kind": escaped], "promptSource": escaped, "operation": escaped,
      "attachment": ["source_uuid": "attachment-" + escaped], escaped: "Invented key value",
      nestedEscaped: "Invented deeply escaped key"]
    let batch = try importInvented(fields, name: "invented-safe-metadata", at: 200)
    _ = try importInvented(["type": escaped, "timestamp": 100, "role": escaped,
      "sessionId": escaped, "uuid": escaped, "operation": escaped], name: "invented-safe-type", at: 200)
    let label = "password".map { String(format: "\\u%04x", $0.asciiValue!) }.joined()
    let malformed = "{\"" + label.replacingOccurrences(of: "\\", with: "\\\\") + "\":\"invented-labelled-secret\""
    let malformedURL = try file(.claude, name: "invented-escaped-label.jsonl")
    try write([malformed], to: malformedURL)
    let malformedSource = try XCTUnwrap(reader(.claude).files().first { $0.path == malformedURL.path })
    let malformedBatch = try AgentLogFiles.read(malformedSource, tool: .claude, position: nil, at: 200)
    try store.appendLogEvents(malformedBatch.events, evidence: malformedBatch.evidence, position: malformedBatch.position)
    let parsed = try XCTUnwrap(batch.events.first)
    XCTAssertEqual(parsed.session?.storedKey, AgentLogEventParser.rawIdentity(escaped))
    XCTAssertEqual(parsed.role, "[secret]")
    XCTAssertEqual(try AgentLogState.decode(batch.position.state).session?.storedKey, AgentLogEventParser.rawIdentity(escaped))
    let saved = try XCTUnwrap(store.logPosition(path: batch.position.path))
    XCTAssertEqual(try AgentLogState.decode(saved.state).session?.storedKey, AgentLogEventParser.rawIdentity(escaped))
    var untrusted = parsed
    untrusted.offset = 999
    untrusted.session = AgentLogIdentityCodec.session(escaped)
    untrusted.project = escaped
    untrusted.type = escaped
    untrusted.role = escaped
    untrusted.flags = [escaped]
    untrusted.identities = ["claude:" + escaped, "claude:alias-" + escaped].map(AgentLogIdentityCodec.instruction)
    untrusted.parseStatus = escaped
    untrusted.payload = try json([escaped: escaped])
    let evidence = EvidenceText(ts: 100, kind: .prompt, source: escaped,
      sourceID: "claude:" + escaped, sourceAliases: ["claude:alias-" + escaped],
      documentKey: escaped, project: escaped, text: escaped)
    let state = try json(["session": escaped, "project": escaped,
      "queued": [["hash": escaped, "id": escaped, "ts": 100, "delivered": true]], "metadataRead": true])
    let position = LogPosition(path: "invented-direct", device: 2, inode: 3, offset: 1000, state: state, seenAt: 200)
    try store.appendLogEvents([untrusted], evidence: [evidence], position: position)
    try store.saveLogPosition(position)
    XCTAssertEqual(try AgentLogState.decode(try XCTUnwrap(store.logPosition(path: position.path)).state).session?.storedKey, "[secret]")
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: 300)
    try store.saveSettings(StorageSettings(), at: 400)
    untrusted.timestamp = 350
    untrusted.offset = 1001
    try store.appendLogEvents([untrusted], evidence: [], position: position)
    // The safe identity also matches a later plain spelling and remains refused.
    let count = try eventCount()
    untrusted.timestamp = 450
    untrusted.offset = 1002
    untrusted.identities = ["claude:" + secret].map(AgentLogIdentityCodec.instruction)
    try store.appendLogEvents([untrusted], evidence: [], position: position)
    XCTAssertEqual(try eventCount(), count)
    for suffix in ["", "-wal"] {
      let bytes = (try? Data(contentsOf: root.appendingPathComponent("invented.sqlite" + suffix))) ?? Data()
      for unsafe in [secret, escaped, nestedEscaped, "invented-labelled-secret",
        escaped.replacingOccurrences(of: "\\", with: "\\\\"),
        nestedEscaped.replacingOccurrences(of: "\\", with: "\\\\")] {
        XCTAssertNil(bytes.range(of: Data(unsafe.utf8)))
      }
    }
  }
  func testNativeUUIDsStayDistinctThroughActualReaderStorageAndCheckpoint() throws {
    let ids = ["01234567-89ab-cdef-0123-456789abcdef", "fedcba98-7654-3210-fedc-ba9876543210"]
    for index in ids.indices {
      let name = "rollout-1970-01-01T00-00-01-" + ids[index]
      let url = try file(.codex, name: name + ".jsonl")
      try write([json(["type": "session_meta", "payload": ["id": ids[index]]]),
        json(["type": "event_msg", "timestamp": stamp(100 + index), "payload": [
          "type": "item_completed", "thread_id": ids[index], "turn_id": ids[1-index],
          "item": ["type": "UserMessage", "id": ids[index],
            "content": [["type": "text", "text": "Invented instruction"]]]]])], to: url)
    }
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try eventCount(), 4)
    let evidence = try store.evidence(in: all)
    XCTAssertEqual(evidence.map(\.sourceID), ids.indices.map { "codex:" + ids[$0] + ":" + ids[1-$0] + ":" + ids[$0] })
    XCTAssertEqual(Set(evidence.map(\.source)).count, 2)
    for source in try reader(.codex).files() {
      let saved = try XCTUnwrap(store.logPosition(path: source.path))
      let expected = ids.first { source.path.contains($0) }
      XCTAssertEqual(try AgentLogState.decode(saved.state).session?.storedKey, expected)
    }
    try task.scan(at: 201)
    XCTAssertEqual(try store.evidence(in: all).count, 2)
    XCTAssertEqual(try eventCount(), 4)
  }
  func testClosedMetadataFreeSourcesRetainEveryKindAndHumanProjectionWithoutDeferral() throws {
    let url = try file(.claude)
    let human = try json(["type": "user", "timestamp": stamp(100), "uuid": "no-cwd-human",
      "message": ["role": "user", "content": "Invented ordinary prompt"]])
    let records = [human, "{invalid", "", "{}", try json(["type": "assistant", "timestamp": 101])]
    try write(records, to: url)
    for iteration in 0..<3 {
      try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200 + iteration)
      XCTAssertEqual(try eventCount(), records.count)
      XCTAssertEqual(try store.evidence(in: all).count, 1)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, try Data(contentsOf: url).count)
      store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    }
  }
  func testExternalCwdBeforeOwnMarkerExcludesSameBatchAndPurgesAcrossRestartForBothTools() throws {
    for tool in AgentLogTool.allCases {
      for split in [false, true] {
        let url = try file(tool, name: "invented-late-own-\(tool)-\(split).jsonl")
        let early = try json(["type": "file-history-snapshot", "cwd": "/invented/external", "timestamp": 100])
        let own = tool == .codex
          ? try json(["type": "session_meta", "payload": ["originator": AgentWindowIdentity.codexOriginator]])
          : try json(["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder])
        if split {
          try write([early, prompt(tool, id: "own-\(tool)-\(split)")], to: url)
          try AgentLogTask(reader: reader(tool), storage: store).scan(at: 200)
          XCTAssertEqual(try eventCount(), 2)
          XCTAssertEqual(try store.evidence(in: all).count, 1)
          store = nil
          store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
          try append(Data((own + "\n").utf8), to: url)
        } else { try write([early, own], to: url) }
        try AgentLogTask(reader: reader(tool), storage: store).scan(at: 201)
        XCTAssertEqual(try eventCount(), 0)
        XCTAssertTrue(try store.evidence(in: all).isEmpty)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
        XCTAssertTrue(try AgentLogState.decode(try XCTUnwrap(store.logPosition(path: url.path)).state).ownWorkingFolder == true)
      }
    }
  }
  func testOwnRegistryRejectsSessionHomeAndPathBeforeAnyMetadataAndSurvivesRestart() throws {
    for tool in AgentLogTool.allCases {
      for kind in ["session", "home", "path"] {
        let id = UUID().uuidString
        let home = root.appendingPathComponent("invented-own-\(tool)-\(kind)")
        let url = try file(tool, home: home, name: tool == .codex ? "rollout-invented-" + id + ".jsonl" : id + ".jsonl")
        try write(["", "{malformed", "{}", prompt(tool, id: "invented-registry")], to: url)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        if kind == "session" { try registry.registerSession(id, tool: tool) }
        if kind == "home" { try registry.registerHome(home, tool: tool) }
        if kind == "path" { try registry.registerPath(url, tool: tool) }
        let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first)
        let batch = try AgentLogFiles.read(source, tool: tool, position: nil, at: 200,
          ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertTrue(batch.evidence.isEmpty)
        XCTAssertEqual(batch.position.offset, try Data(contentsOf: url).count)
        try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      }
    }
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertTrue(try store.evidence(in: all).isEmpty)
  }
  func testOwnRegistryUsesExactPathHashesWithoutCollapsingExternalFolders() throws {
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    let base = root.appendingPathComponent("Library/Application Support/ActivityProbe")
    let own = base.appendingPathComponent("codex")
    let external = base.appendingPathComponent("invented-external")
    try registry.registerHome(own, tool: .codex)
    XCTAssertTrue(try registry.contains(path: own.appendingPathComponent("sessions/invented.jsonl").path, tool: .codex))
    XCTAssertFalse(try registry.contains(path: external.appendingPathComponent("sessions/invented.jsonl").path, tool: .codex))
    try registry.registerSession("invented-own-session", tool: .claude)
    XCTAssertFalse(try registry.containsSession("invented-external-session", tool: .claude))
  }
  func testOwnSourcePurgeAndCheckpointRollBackTogether() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "invented-purge-atomic")], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    let original = try XCTUnwrap(store.logPosition(path: url.path))
    try append(Data((try json(["cwd": "/invented/" + AgentWindowIdentity.relativeFolder]) + "\n").utf8), to: url)
    try store.connection.run("CREATE TRIGGER invented_checkpoint_failure BEFORE UPDATE ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
    XCTAssertThrowsError(try task.scan(at: 201))
    XCTAssertEqual(try eventCount(), 1)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.logPosition(path: url.path)?.offset, original.offset)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_own_sources"), 0)
    try store.connection.run("DROP TRIGGER invented_checkpoint_failure")
    try task.scan(at: 202)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertTrue(try store.evidence(in: all).isEmpty)
    XCTAssertEqual(try store.logPosition(path: url.path)?.offset, try Data(contentsOf: url).count)
  }
  func testLateOwnMarkerPreservesLegacyEvidenceWithoutPhysicalProvenance() throws {
    let url = try file(.claude, name: "invented-pre-receipt.jsonl")
    try store.appendEvidence([EvidenceText(ts: 100, kind: .prompt, source: "invented-pre-receipt",
      sourceID: "claude:legacy-own-c", sourceAliases: ["claude:legacy-own-b"], text: "Invented own instruction")])
    try store.appendEvidence([EvidenceText(ts: 101, kind: .prompt, source: "invented-pre-receipt",
      sourceID: "claude:legacy-own-b", sourceAliases: ["claude:legacy-own-a"], text: "Invented own instruction")])
    try write([json(["type": "assistant", "uuid": "legacy-own-a", "timestamp": 100])], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try eventCount(), 1)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), 0)
    try append(Data((try json(["cwd": "/invented/" + AgentWindowIdentity.relativeFolder]) + "\n").utf8), to: url)
    try task.scan(at: 201)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }
  func testMainAdoptionLearnsEdgesWithoutRewritingHistoricalRows() throws {
    try store.appendEvidence([EvidenceText(ts: 100, kind: .prompt, source: "invented-legacy",
      sourceID: "claude:legacy-b", text: "Invented legacy instruction")])
    let position = LogPosition(path: "invented-legacy", device: 10, inode: 20, offset: 30, state: "{}", seenAt: 200)
    try store.saveLogPosition(position)
    let evidence = try store.evidence(in: all)
    let history = try store.logRecordingHistory()
    let settings = try store.settings()
    try makeMainLogOrigin(store)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    XCTAssertEqual(try store.evidence(in: all), evidence)
    XCTAssertEqual(try store.logRecordingHistory(), history)
    XCTAssertEqual(try store.settings(), settings)
    XCTAssertEqual(try store.logPosition(path: position.path)?.offset, position.offset)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.appendEvidence([EvidenceText(ts: 200, kind: .prompt, source: "invented-current",
      sourceID: "claude:legacy-b", sourceAliases: ["claude:legacy-a"], text: "Invented legacy instruction")]).stored, 0)
    XCTAssertEqual(try store.appendEvidence([EvidenceText(ts: 300, kind: .prompt, source: "invented-new",
      sourceID: "claude:legacy-c", sourceAliases: ["claude:legacy-a"], text: "Invented legacy instruction")]).stored, 0)
    XCTAssertEqual(try store.evidence(in: all), evidence)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_prompt_lineage WHERE alias='claude:legacy-a'"), 2)
  }
  func testRepeatedAliasKeepsBranchingLineageForEveryRoleOrderPrivacyAndRestart() throws {
    var iteration = 0
    for privacy in ["off", "pause", "forget"] {
      for reverse in [false, true] {
        for role in ["user", "assistant", "tool", "system"] {
          let base = iteration * 1000
          let a = "branch-a-\(iteration)", b = "branch-b-\(iteration)", c = "branch-c-\(iteration)"
          let prefix = "invented-branch-\(iteration)"
          func load(_ id: String, command: String? = nil, _ time: Int) throws {
            var fields: [String: Any] = ["type": role, "timestamp": stamp(base + time), "uuid": id,
              "message": ["role": role, "content": "Invented branching instruction"]]
            if let command { fields["commandUuid"] = command }
            _ = try importInvented(fields, name: prefix + "-\(time)", at: base + 600)
          }
          let initialPrompts = try store.evidence(in: all).count
          try load(a, command: reverse ? c : b, 100)
          let preview = try store.previewDeletion(in: TimeRange(base + 100, base + 101))
          try load(a, command: reverse ? b : c, 200)
          XCTAssertNotEqual(try store.previewDeletion(in: TimeRange(base + 100, base + 101)).confirmation, preview.confirmation)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_prompt_edges WHERE alias=?", [.key("claude:" + a)]), 2)
          try load(c, 300)
          XCTAssertEqual(try store.evidence(in: all).count - initialPrompts, role == "user" ? 1 : 0)
          if privacy == "forget" {
            let range = TimeRange(base + 100, base + 101)
            let deletion = try store.previewDeletion(in: range)
            try store.deleteRecords(in: range, confirmation: deletion.confirmation)
          } else {
            try store.saveSettings(privacy == "off" ? StorageSettings(recordingEnabled: false) : StorageSettings(pausedUntil: base + 500), at: base + 400)
            try store.saveSettings(StorageSettings(), at: base + 500)
            try load(b, 450)
          }
          let before = try eventCount()
          let promptsBefore = try store.evidence(in: all).count
          store = nil
          store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
          try load(c, 550)
          try load(b, 551)
          XCTAssertEqual(try eventCount(), before, "\(privacy) \(reverse) \(role)")
          XCTAssertEqual(try store.evidence(in: all).count, promptsBefore)
          for id in [a, b, c] {
            XCTAssertGreaterThan(try store.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source_id=?", [.key("claude:" + id)]), 0)
          }
          iteration += 1
        }
      }
    }
  }
}
