import Core
import CryptoKit
import Foundation
import XCTest

@testable import Inbound
@testable import Shell
@testable import Storage

/// Invented readers expose deterministic boundaries without touching any OS process or live log.
final class ControlledLogReader: AgentLogReader {
  let name = "invented-controlled"
  var listed: [AgentLogFile] = []
  var beforeListing: () throws -> Void = {}
  var beforeRead: (AgentLogFile) throws -> Void = { _ in }
  var reads: [String] = []
  func files() throws -> [AgentLogFile] {
    try beforeListing()
    return listed
  }
  func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch {
    reads.append(file.path)
    try beforeRead(file)
    return try AgentLogFiles.read(file, tool: .claude, position: position, at: time)
  }
}

extension AgentLogTests {
  func claudeRow(_ fields: [String: Any], at time: Int = 100) throws -> String {
    var row = try JSONSerialization.jsonObject(with: Data(prompt(.claude, id: "invented-mark", at: time).utf8))
      as! [String: Any]
    for (key, value) in fields { row[key] = value }
    return try json(row)
  }
  func queued(_ id: String, at time: Int, fields: [String: Any] = [:]) throws -> String {
    var attachment: [String: Any] = [
      "type": "queued_command", "source_uuid": id, "commandMode": "prompt", "humanTurn": true,
      "prompt": "Invented repeated queue words", "timestamp": stamp(time),
    ]
    for (key, value) in fields { attachment[key] = value }
    return try json(["type": "attachment", "timestamp": stamp(time), "attachment": attachment])
  }
  func enqueue(_ id: String, at time: Int) throws -> String {
    try json([
      "type": "queue-operation", "operation": "enqueue", "commandUuid": id,
      "content": "Invented repeated queue words", "timestamp": stamp(time),
    ])
  }
  func queuedCopy(_ id: String, at time: Int) throws -> String {
    try claudeRow([
      "uuid": id, "promptSource": "queued",
      "message": ["content": "Invented repeated queue words"],
    ], at: time)
  }
  func testQueuedDeliveryPairsOnceAcrossCheckpointAndDatesAtEnqueue() throws {
    for shape in ["pair", "attachment", "copy", "repeat", "consumed"] {
      let url = try file(.claude, name: "invented-queue-" + shape + ".jsonl")
      let id = "invented-" + shape
      let lines = shape == "copy" ? [try queuedCopy(id, at: 96)]
        : [try enqueue(id, at: 90), try queued(id, at: 95)]
      try write(lines, to: url)
      let task = AgentLogTask(reader: reader(.claude), storage: store)
      try task.scan(at: 200)
      let checkpoint = try XCTUnwrap(store.logPosition(path: url.path))
      XCTAssertFalse(checkpoint.state.contains("Invented repeated queue words"))
      let state = try AgentLogState.decode(checkpoint.state)
      XCTAssertEqual(try AgentLogState.decode(state.encoded()), state)
      if shape == "pair" || shape == "repeat" || shape == "consumed" {
        try append(Data((try queuedCopy(id + "-copy", at: 96) + "\n").utf8), to: url)
      }
      if shape == "repeat" {
        try append(Data((try [enqueue(id + "-later", at: 110), queued(id + "-later", at: 115),
          queuedCopy(id + "-later-copy", at: 116)].joined(separator: "\n") + "\n").utf8), to: url)
      }
      if shape == "consumed" {
        try append(Data((try queuedCopy(id + "-unpaired", at: 120) + "\n").utf8), to: url)
      }
      try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 300)
      let rows = try store.evidence(in: all).filter { $0.source == "invented-queue-" + shape }
      XCTAssertEqual(rows.count, shape == "repeat" || shape == "consumed" ? 2 : 1, shape)
      XCTAssertEqual(rows.first?.ts, shape == "copy" ? 96 : 90, shape)
      XCTAssertEqual(rows.first?.sourceID, "claude:" + id, shape)
      if shape == "repeat" { XCTAssertEqual(rows.last?.ts, 110) }
    }
  }
  func testClaudeToolMarksEachRefuseAndCountOnlyTheirKind() throws {
    let marks: [([String: Any], AgentLogIgnore)] = [
      (["isMeta": true], .meta), (["isCompactSummary": true], .compactSummary),
      (["isVisibleInTranscriptOnly": true], .transcriptOnly), (["isSidechain": true], .sidechain),
      (["origin": ["kind": "task-notification"]], .taskNotification),
      (["origin": ["kind": "peer"]], .peer), (["origin": ["kind": "automation"]], .automation),
      (["origin": ["kind": "scheduled-task"]], .automation),
      (["origin": ["kind": "tool"]], .nonHumanOrigin),
      (["scheduledTaskId": "invented-task"], .automation), (["scheduledFireId": "invented-fire"], .automation),
      (["promptSource": "system"], .nonHumanOrigin), (["promptSource": "sdk"], .nonHumanOrigin),
      (["toolUseResult": ["invented": true]], .toolUseResult),
      (["message": ["content": [
        ["type": "text", "text": "Invented tool result label"],
        ["type": "tool_result", "content": "Invented output"],
      ]]], .toolResult),
    ]
    for (index, entry) in marks.enumerated() {
      let url = try file(.claude, name: "invented-mark-\(index).jsonl")
      try write([claudeRow(entry.0)], to: url)
      let batch = try AgentLogFiles.read(try XCTUnwrap(reader(.claude).files().first { $0.path == url.path }),
        tool: .claude, position: nil, at: 200)
      XCTAssertEqual(batch.evidence, [], "mark \(index)")
      XCTAssertEqual(batch.ignored, [entry.1: 1], "mark \(index)")
    }
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 0)
    XCTAssertEqual(task.health.ignored.values.reduce(0, +), marks.count)
    XCTAssertEqual(task.health.ignored[.automation], 4)
    let url = try file(.claude, name: "invented-clear.jsonl")
    try write([claudeRow(["isMeta": false, "isSidechain": false, "origin": ["kind": "human"]])], to: url)
    try task.scan(at: 500)
    XCTAssertEqual(task.health.stored, 1)
  }
  func testQueuedAttachmentMarksAndSubagentFilesAreCounted() throws {
    let marks: [([String: Any], AgentLogIgnore)] = [
      (["commandMode": "task-notification"], .taskNotification), (["humanTurn": false], .nonHumanOrigin),
      (["origin": ["kind": "peer"]], .peer), (["isMeta": true], .meta),
    ]
    let url = try file(.claude)
    try write(try marks.enumerated().map { try queued("invented-\($0.offset)", at: 100, fields: $0.element.0) },
      to: url)
    let nested = url.deletingLastPathComponent().appendingPathComponent("invented-session/subagents")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try write([prompt(.claude, id: "invented-subagent")], to: nested.appendingPathComponent("invented-agent.jsonl"))
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.stored, 0)
    XCTAssertEqual(task.health.ignored, [
      .taskNotification: 1, .nonHumanOrigin: 1, .peer: 1, .meta: 1, .subagent: 1,
    ])
    XCTAssertEqual(try store.logPosition(path: url.path)?.offset, (try Data(contentsOf: url)).count)
  }
  func testCodexSessionAndItemMarksPersistWhileExecIsAccepted() throws {
    let marks: [([String: Any], AgentLogIgnore)] = [
      (["thread_source": "subagent"], .subagent), (["source": "subagent"], .subagent),
      (["source": ["subagent": ["thread_spawn": ["parent_thread_id": "invented-parent"]]]], .subagent),
      (["parent_thread_id": "invented-parent"], .subagent),
      (["thread_source": "task-notification"], .taskNotification),
      (["source": "automation"], .automation), (["thread_source": "scheduled-task"], .automation),
      (["origin": ["kind": "automation"]], .automation), (["origin": ["kind": "peer"]], .peer),
    ]
    for (index, entry) in marks.enumerated() {
      let url = try file(.codex, name: "invented-codex-mark-\(index).jsonl")
      var payload: [String: Any] = ["id": "invented-session", "cwd": "/invented/project"]
      for (key, value) in entry.0 { payload[key] = value }
      try write([json(["type": "session_meta", "payload": payload])], to: url)
      let file = try XCTUnwrap(reader(.codex).files().first { $0.path == url.path })
      let header = try AgentLogFiles.read(file, tool: .codex, position: nil, at: 200)
      try append(Data((try prompt(.codex, id: "invented-marked") + "\n").utf8), to: url)
      let grown = try XCTUnwrap(reader(.codex).files().first { $0.path == url.path })
      let batch = try AgentLogFiles.read(grown, tool: .codex, position: header.position, at: 300)
      XCTAssertEqual(batch.evidence, [], "session mark \(index)")
      XCTAssertEqual(batch.ignored, [entry.1: 1], "session mark \(index)")
    }
    for level in ["line", "payload", "item"] {
      var line = try JSONSerialization.jsonObject(with: Data(prompt(.codex, id: "invented-item-mark").utf8))
        as! [String: Any]
      var payload = line["payload"] as! [String: Any]
      var item = payload["item"] as! [String: Any]
      if level == "line" { line["origin"] = ["kind": "task-notification"] }
      if level == "payload" { payload["source"] = "automation" }
      if level == "item" { item["source"] = "subagent" }
      payload["item"] = item
      line["payload"] = payload
      var state = AgentLogState()
      guard case .excluded = AgentLogParser.parse(try json(line), tool: .codex, file: "/invented/session.jsonl",
        state: &state, fingerprint: AgentLogFiles.fingerprint) else { return XCTFail(level) }
    }
    let url = try file(.codex, name: "invented-exec.jsonl")
    try write([
      json(["type": "session_meta", "payload": [
        "source": "exec", "thread_source": "exec", "originator": "codex_exec",
      ]]), prompt(.codex, id: "invented-person-exec"),
    ], to: url)
    let task = AgentLogTask(reader: reader(.codex), storage: store)
    try task.scan(at: 400)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.ignored.values.reduce(0, +), marks.count)
  }
  func testConnectionRevokedByListingPreventsEvenFirstRead() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "invented-one")], to: url)
    let reader = ControlledLogReader()
    reader.listed = try AgentLogFiles.enumerate([url.deletingLastPathComponent().path])
    reader.beforeListing = { try self.store.saveFixtureSettings(StorageSettings(), at: 150) }
    let task = AgentLogTask(reader: reader, storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(reader.reads, [])
    XCTAssertNil(try store.logPosition(path: url.path))
  }
  func testReadAcceptsGrowthSinceListingAndFailureDoesNotSkipNextFile() throws {
    let one = try file(.claude, name: "invented-a.jsonl")
    let two = try file(.claude, name: "invented-b.jsonl")
    try write([prompt(.claude, id: "one")], to: one)
    try write([prompt(.claude, id: "two")], to: two)
    let files = try AgentLogFiles.enumerate([one.deletingLastPathComponent().path])
    try append(Data((try prompt(.claude, id: "three", at: 101) + "\n").utf8), to: one)
    XCTAssertEqual(try AgentLogFiles.read(files[0], tool: .claude, position: nil, at: 200).evidence.count, 2)
    let reader = ControlledLogReader()
    reader.listed = files
    try FileManager.default.removeItem(at: one)
    let task = AgentLogTask(reader: reader, storage: store)
    XCTAssertThrowsError(try task.scan(at: 200))
    XCTAssertEqual(task.health.fileFailures, 1)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(reader.reads.count, 2)
    XCTAssertNotNil(try store.logPosition(path: two.path))
  }
  func testLinkedLogRootBadFolderAndOtherHomesAreAllVisitedWithoutAliases() throws {
    let target = root.appendingPathComponent("invented-target")
    let link = root.appendingPathComponent(".claude/projects")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try write([prompt(.claude, id: "one")], to: target.appendingPathComponent("invented-one.jsonl"))
    let badHome = root.appendingPathComponent("invented-bad")
    try FileManager.default.createDirectory(at: badHome, withIntermediateDirectories: true)
    try Data("Invented regular file".utf8).write(to: badHome.appendingPathComponent("projects"))
    let goodHome = root.appendingPathComponent("invented-good")
    let other = try file(.claude, home: goodHome, name: "invented-two.jsonl")
    try write([prompt(.claude, id: "two")], to: other)
    processes.listed = [AgentLogProcess(pid: 1, tool: .claude), AgentLogProcess(pid: 2, tool: .claude)]
    processes.homes = [1: badHome.path, 2: goodHome.path]
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    XCTAssertThrowsError(try task.scan(at: 200))
    XCTAssertEqual(task.health.stored, 2)
    XCTAssertEqual(task.health.folderFailures, 1)
    XCTAssertEqual(task.health.failures, 1)
    XCTAssertEqual(try AgentLogFiles.enumerate([link.path, target.path]).count, 1)
    // A hard link has a different path but the same device and inode.
    let alias = target.appendingPathComponent("invented-hardlink.jsonl")
    try FileManager.default.linkItem(at: target.appendingPathComponent("invented-one.jsonl"), to: alias)
    XCTAssertEqual(try AgentLogFiles.enumerate([target.path]).count, 1)
  }
  func testShrinkDuringReadRefusesBatchWithoutAdvancingPosition() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "one")], to: url)
    let listed = try XCTUnwrap(reader(.claude).files().first)
    XCTAssertThrowsError(try AgentLogFiles.readFile(listed, tool: .claude, position: nil, at: 200) {
      let writer = try FileHandle(forWritingTo: url)
      defer { try? writer.close() }
      try writer.truncate(atOffset: 0)
    })
    XCTAssertNil(try store.logPosition(path: url.path))
  }
  func testPrivacyHistoryOnlyChangesWithRecordingOrPauseAndIsNeverPruned() throws {
    let initial = try store.logRecordingHistory()
    var settings = try store.settings()
    for index in 1...200 {
      settings.promptRetentionDays = index
      settings.subscriptionConnected = index % 2 == 0
      try store.saveFixtureSettings(settings, at: index)
    }
    XCTAssertEqual(try store.logRecordingHistory(), initial)
    settings.pausedUntil = 500
    try store.saveFixtureSettings(settings, at: 201)
    settings.recordingEnabled = false
    try store.saveFixtureSettings(settings, at: 202)
    settings.pausedUntil = nil
    try store.saveFixtureSettings(settings, at: 203)
    let changed = try store.logRecordingHistory()
    XCTAssertEqual(changed.count, initial.count + 3)
    let preview = try store.previewDeletion(in: TimeRange(201, 204))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    _ = try store.cleanRetention(at: 100000000)
    XCTAssertEqual(try store.logRecordingHistory(), changed)
  }
  func testPromptRetentionCutoffRefusesOldRowsButAdvancesPosition() throws {
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true, promptRetentionDays: 1), at: 0)
    let url = try file(.claude)
    try write([
      prompt(.claude, id: "old", at: 99), prompt(.claude, id: "boundary", at: 100),
      prompt(.claude, id: "new", at: 101),
    ], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 86500)
    XCTAssertEqual(task.health.stored, 2)
    XCTAssertEqual(task.health.refused, 1)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [100, 101])
    XCTAssertEqual(try store.logPosition(path: url.path)?.offset, (try Data(contentsOf: url)).count)
    try task.scan(at: 86501)
    XCTAssertEqual(task.health.refused, 1)
  }
  func testEmptyArgv0AndPaddingHaveIdenticalBytesWithoutAnExternalBoundary() {
    var argc: Int32 = 1
    let prefix = withUnsafeBytes(of: &argc) { Data($0) } + Data("/invented/codex\0".utf8)
    let argument = "CODEX_HOME=/invented/argument\0"
    let neighbour = "TOKEN=/invented/other\0"
    // One padding NUL plus a named argument has exactly the bytes of an empty argv[0] plus that environment.
    let namedArgument = prefix + Data([0]) + Data(argument.utf8) + Data(neighbour.utf8)
    let emptyArgv0 = prefix + Data("\0".utf8) + Data((argument + neighbour).utf8)
    XCTAssertEqual(namedArgument, emptyArgv0)
    XCTAssertNil(namedArgument.withUnsafeBytes {
      NamedProcessVariable.value("CODEX_HOME", inProcessArguments: $0)
    })
  }

}
