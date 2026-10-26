import Foundation
import XCTest
@testable import Core
@testable import Inbound
@testable import Shell
@testable import Storage

extension AgentLogTests {
  func parsed(_ line: String, tool: AgentLogTool = .claude, file: String = "/invented/projects/test.jsonl",
    state: inout AgentLogState) -> AgentLogLine
  {
    AgentLogParser.parse(line, tool: tool, file: file, state: &state, fingerprint: AgentLogFiles.fingerprint)
  }
  func parsedPrompt(_ line: String, tool: AgentLogTool = .claude, state: inout AgentLogState) throws -> EvidenceText {
    guard case .prompt(let row) = parsed(line, tool: tool, state: &state) else {
      XCTFail("Expected invented prompt")
      throw StorageError.broken("Expected invented prompt")
    }
    return row
  }
  func testNativeClaudeIDRefusesCopiedSessionAcrossSourcesButNotLegacyOrOtherKinds() throws {
    let parent = try file(.claude, name: "invented-parent.jsonl")
    let child = try file(.claude, name: "invented-child.jsonl")
    let shared = try prompt(.claude, id: "invented-shared")
    try write([shared], to: parent)
    try write([shared], to: child)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(task.health.refused, 1)
    XCTAssertEqual(try eventCount(), 2)
    let rows = ["invented-a", "invented-b"].map {
      EvidenceText(ts: 101, kind: .prompt, source: $0, sourceID: "claude:legacy:101:invented", text: "Invented text")
    }
    XCTAssertEqual(try store.appendEvidence(rows).stored, 2)
    let other = EvidenceText(ts: 102, kind: .prompt, source: "invented-c", sourceID: "claude:kind", text: "Invented")
    try store.connection.run(
      "INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(102,'screen','a',?,'','','')",
      [.text("claude:kind")])
    XCTAssertEqual(try store.appendEvidence([other]).stored, 1)
  }
  func codexRow(_ fields: [String: Any]) throws -> String {
    var line = try JSONSerialization.jsonObject(with: Data(prompt(.codex, id: "invented-item").utf8))
      as! [String: Any]
    var payload = line["payload"] as! [String: Any]
    for (key, value) in fields { payload[key] = value }
    line["payload"] = payload
    return try json(line)
  }
  func testImportedCodexTurnIsCountedAndNextHumanTurnSurvives() throws {
    let url = try file(.codex)
    try write([meta(.codex), codexRow(["turn_id": "external-import-turn-1"]),
      codexRow(["turn_id": "invented-person-turn"])], to: url)
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.ignored, [.imported: 1])
    XCTAssertEqual(try eventCount(), 3)
    XCTAssertEqual(try eventCount("flags LIKE '%imported%'"), 1)
  }
  func testOwnWindowSessionsUseSharedIdentitiesAndLateFolderProof() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      let own = "/invented/home/" + AgentWindowIdentity.relativeFolder
      let header = tool == .codex
        ? try json(["type": "session_meta", "payload": ["originator": AgentWindowIdentity.codexOriginator]])
        : try json(["type": "assistant", "cwd": own + "/invented-session"])
      try write([header, prompt(tool, id: "invented-own-window")], to: url)
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.stored, 0)
      XCTAssertEqual(task.health.ignored, [.ownWindow: 2])
    }
    var state = AgentLogState()
    _ = parsed(try json(["type": "assistant", "cwd": "/invented/project"]), state: &state)
    guard case .excluded(.ownWindow) = parsed(
      try claudeRow(["cwd": "/invented/home/" + AgentWindowIdentity.relativeFolder]), state: &state) else {
      return XCTFail("Later positive folder proof must match all-role parsing and recovery")
    }
    XCTAssertFalse(AgentWindowIdentity.containsWorkingFolder(
      "/invented/home/" + AgentWindowIdentity.relativeFolder + "-similar"))
    XCTAssertTrue(AgentWindowIdentity.containsWorkingFolder("/invented/home/" + AgentWindowIdentity.relativeFolder))
    var ownState = AgentLogState()
    _ = parsed(try json(["type": "assistant", "cwd": "/invented/home/" + AgentWindowIdentity.relativeFolder]), state: &ownState)
    ownState = try AgentLogState.decode(ownState.encoded())
    guard case .excluded(.ownWindow) = parsed(try claudeRow([:]), state: &ownState) else {
      return XCTFail("own working folder identity must survive masked state and restart")
    }
  }
  func testChatGPTPlanOriginatorIsExcludedFromAgentLogImports() throws {
    let url = try file(.codex)
    let header = try json(["type": "session_meta", "payload": ["originator": AgentWindowIdentity.codexPlanOriginator]])
    try write([header, prompt(.codex, id: "invented-own-plan-window")], to: url)
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 0)
    XCTAssertEqual(task.health.ignored, [.ownWindow: 2])
  }
  func testFixedWrappersCountByKindAndTypedCommandsSurvive() throws {
    let wrappers: [(String, AgentLogIgnore)] = [
      ("<task-notification>Invented", .taskNotification), ("<local-command-stdout>Invented", .localCommandOutput),
      ("<local-command-stderr>Invented", .localCommandOutput), ("<bash-stdout>Invented", .shellOutput),
      ("<bash-stderr>Invented", .shellOutput), ("[Request interrupted by user for tool use]", .interruption),
    ]
    for (text, reason) in wrappers {
      var state = AgentLogState()
      guard case .excluded(let mark) = parsed(try claudeRow(["message": ["content": text]]), state: &state)
      else { return XCTFail(text) }
      XCTAssertEqual(mark, reason)
    }
    for text in ["<command-name>/invented</command-name>", "<bash-input>invented</bash-input>",
      "<local-command-caveat>Invented", "Caveat: Invented", "[Request interrupted elsewhere]"]
    {
      var state = AgentLogState()
      XCTAssertEqual(try parsedPrompt(claudeRow(["message": ["content": text]]), state: &state).text, text)
    }
  }
  func testNullableAndEmptyMarksAreNotMarks() throws {
    for value: Any in [NSNull(), "", false, 0] {
      for key in ["scheduledTaskId", "scheduledFireId"] {
        var state = AgentLogState()
        _ = try parsedPrompt(claudeRow([key: value]), state: &state)
      }
      var state = AgentLogState()
      _ = parsed(try json(["type": "session_meta", "payload": ["parent_thread_id": value]]),
        tool: .codex, state: &state)
      _ = try parsedPrompt(prompt(.codex, id: "invented"), tool: .codex, state: &state)
    }
  }
  func testSubagentsMarkOnlyBelowLogsFolder() throws {
    var state = AgentLogState()
    guard case .prompt = parsed(try prompt(.claude, id: "invented"),
      file: "/invented/subagents/home/projects/test.jsonl", state: &state)
    else { return XCTFail("Home names are not tool marks") }
    guard case .excluded(.subagent) = parsed(try prompt(.claude, id: "invented"),
      file: "/invented/home/projects/session/subagents/test.jsonl", state: &state)
    else { return XCTFail("Nested tool subagent folder must be counted") }
  }
  func testSubagentsMarkSurvivesLinkedLogsRootWithNoProjectsComponent() throws {
    let target = root.appendingPathComponent("invented-linked-root")
    let nested = target.appendingPathComponent("session/subagents")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let link = root.appendingPathComponent(".claude/projects")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try write([prompt(.claude, id: "invented-subagent")], to: nested.appendingPathComponent("invented.jsonl"))
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.ignored, [.subagent: 1])
    XCTAssertEqual(task.health.stored, 0)
  }
  func testQueuedPrivacyUsesEachActualOccurrence() throws {
    let url = try file(.claude)
    try store.saveFixtureSettings(StorageSettings(pausedUntil: 100, subscriptionConnected: true), at: 94)
    let preview = try store.previewDeletion(in: TimeRange(94, 97))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    try write([enqueue("invented-enqueued", at: 90), queued("invented-enqueued", at: 95),
      queuedCopy("invented-copy", at: 96)], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 0)
    XCTAssertEqual(try store.evidence(in: all), [])
  }
  func testExcludedUserClearsOnlyEarlierPendingMatchingHashes() throws {
    var state = AgentLogState()
    _ = parsed(try enqueue("invented-early", at: 50), state: &state)
    _ = parsed(try claudeRow(["isMeta": true, "message": ["content": "Invented repeated queue words"]], at: 55),
      state: &state)
    let row = try parsedPrompt(queuedCopy("invented-later", at: 105), state: &state)
    XCTAssertEqual(row.ts, 105)
    XCTAssertEqual(row.sourceID, "claude:invented-later")
    _ = parsed(try enqueue("invented-future", at: 200), state: &state)
    _ = parsed(try claudeRow(["isMeta": true, "message": ["content": "Invented repeated queue words"]], at: 199),
      state: &state)
    XCTAssertEqual(state.queued.map(\.ts), [])
    _ = parsed(try claudeRow(["isMeta": true, "message": ["content": "Invented different words"]], at: 201),
      state: &state)
    XCTAssertEqual(state.queued.count, 0)
    _ = parsed(try claudeRow(["isMeta": true, "message": ["content": "Invented repeated queue words"]], at: 200),
      state: &state)
    XCTAssertEqual(state.queued.count, 0)
  }
  func testAttachmentsRequireHumanMarkAndQueuedSlashCommandSurvives() throws {
    var state = AgentLogState()
    let unmarked = try json(["type": "attachment", "timestamp": stamp(100), "attachment": [
      "type": "queued_command", "prompt": "Invented", "source_uuid": "invented-unmarked",
    ]])
    guard case .excluded(.nonHumanOrigin) = parsed(unmarked, state: &state)
    else { return XCTFail("An unmarked attachment is not a human turn") }
    let slash = try queued("invented-slash", at: 100, fields: [
      "commandMode": "command", "prompt": "<command-name>/invented</command-name>",
    ])
    _ = try parsedPrompt(slash, state: &state)
    _ = try parsedPrompt(queued("invented-origin", at: 101, fields: [
      "humanTurn": NSNull(), "origin": ["kind": "human"],
    ]), state: &state)
  }
  func testQueueRowsAreNotCountedOnlyDeliveryIs() throws {
    let url = try file(.claude)
    try write([json(["type": "queue-operation", "operation": "enqueue", "content": "<task-notification>Invented",
      "timestamp": stamp(90), "isMeta": true]),
      queued("invented-notification", at: 95, fields: ["commandMode": "task-notification"])], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.ignored, [.taskNotification: 1])
    XCTAssertEqual(task.health.stored, 0)
  }
  func testNoTextCandidatesCountAsEmpty() throws {
    let one = try file(.claude)
    let two = try file(.codex)
    try write([claudeRow(["message": ["content": [["type": "document"]]]])], to: one)
    try write([codexRow(["item": ["type": "UserMessage", "content": [["type": "mention"]]]])], to: two)
    for tool in AgentLogTool.allCases {
      let task = AgentLogTask(reader: reader(tool), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(task.health.ignored, [.empty: 1])
    }
  }
  func testQueueReplacementRemovalAndHashTimeGuard() throws {
    var state = AgentLogState()
    _ = parsed(try enqueue("invented-old", at: 50), state: &state)
    _ = parsed(try enqueue("invented-new", at: 60), state: &state)
    XCTAssertEqual(state.queued.map(\.id), [])
    _ = parsed(try json(["type": "queue-operation", "operation": "remove", "content": "Invented repeated queue words",
      "timestamp": stamp(70)]), state: &state)
    XCTAssertEqual(state.queued.count, 0)
    _ = parsed(try enqueue("invented-future", at: 100), state: &state)
    let row = try parsedPrompt(queued("invented-unmatched", at: 95), state: &state)
    XCTAssertEqual(row.ts, 95)
  }
  func testQueueBoundAfterEnqueuesAndAttachmentsAndDecode() throws {
    for attachment in [false, true] {
      var state = AgentLogState()
      for index in 0..<40 {
        let line = attachment ? try queued("invented-\(index)", at: 100 + index,
          fields: ["prompt": "Invented \(index)"])
          : try json(["type": "queue-operation", "operation": "enqueue", "commandUuid": "invented-\(index)",
            "content": "Invented \(index)", "timestamp": stamp(100 + index)])
        _ = parsed(line, state: &state)
      }
      XCTAssertEqual(state.queued.count, 0)
      XCTAssertNil(state.queued.first)
      XCTAssertEqual(try AgentLogState.decode(state.encoded()).queued.count, 0)
    }
    let oversized = try json(["metadataRead": true, "project": "", "queued": (0..<40).map {
      ["hash": "invented-\($0)", "ts": $0, "delivered": false] as [String: Any]
    }])
    XCTAssertEqual(try AgentLogState.decode(oversized).queued.count, 32)
  }
  func testQueuedCopyNeverGuessesOldestDelivery() throws {
    var state = AgentLogState()
    _ = try parsedPrompt(queued("invented-first", at: 50), state: &state)
    _ = try parsedPrompt(queued("invented-second", at: 60), state: &state)
    let row = try parsedPrompt(queuedCopy("invented-copy", at: 70), state: &state)
    XCTAssertEqual(row.sourceID, "claude:invented-copy")
    XCTAssertEqual(row.ts, 70)
  }
  func testCodexPayloadThreadTakesPrecedenceOverHeader() throws {
    var state = AgentLogState()
    state.session = AgentLogIdentityCodec.session("invented-header")
    let row = try parsedPrompt(codexRow(["thread_id": "invented-payload"]), tool: .codex, state: &state)
    XCTAssertEqual(row.sourceID, "codex:invented-payload:invented-turn:invented-item")
  }
  func testOldDeliveredHashCannotEstablishCopyIdentity() throws {
    let url = try file(.claude)
    let copy = try queuedCopy("invented-copy", at: 95)
    try write([copy], to: url)
    let file = try XCTUnwrap(reader(.claude).files().first)
    let old = try json(["folder": "/invented/project", "queued": [[
      "hash": AgentLogFiles.fingerprint("Invented repeated queue words"), "id": "invented-old",
      "ts": 90, "delivered": true,
    ]]])
    try store.appendEvidence([EvidenceText(ts: 90, kind: .prompt, source: "invented",
      sourceID: "claude:invented-old", text: "Invented repeated queue words")])
    try store.saveLogPosition(LogPosition(path: file.path, device: file.device, inode: file.inode,
      offset: 0, state: old, seenAt: 100))
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.refused, 0)
    XCTAssertEqual(try store.evidence(in: all).count, 2)
  }
  func testConvertedCodexCursorRecoversHeaderExclusionBeforeAppend() throws {
    let url = try file(.codex)
    let header = try json(["type": "session_meta", "payload": ["source": "subagent"]])
    try write([header, prompt(.codex, id: "invented-appended")], to: url)
    let file = try XCTUnwrap(reader(.codex).files().first)
    try store.saveLogPosition(LogPosition(path: file.path, device: file.device, inode: file.inode,
      offset: header.utf8.count + 1, state: "{}", seenAt: 100))
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 0)
    XCTAssertEqual(task.health.ignored, [.subagent: 1])
  }
  func testFolderStatAndEnumerationErrorsEachCountAndContinue() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "invented-good")], to: url)
    let cycle = root.appendingPathComponent("invented-cycle")
    try FileManager.default.createSymbolicLink(atPath: cycle.path, withDestinationPath: cycle.path)
    let statResult = try AgentLogFiles.listing([cycle.path, url.deletingLastPathComponent().path])
    XCTAssertEqual(statResult.folderFailures, 1)
    XCTAssertEqual(statResult.files.count, 1)
    let enumerated = try AgentLogFiles.listing([url.deletingLastPathComponent().path], enumerate: { root, onError in
      _ = onError(root, AgentLogReadError.fileUnavailable)
      return FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    })
    XCTAssertEqual(enumerated.folderFailures, 1)
    XCTAssertEqual(enumerated.files.count, 1)
  }
}
