import Foundation
import XCTest
@testable import Core
@testable import Inbound
@testable import Shell
@testable import Storage

extension AgentLogTests {
  func continuedAttachment() throws -> String {
    var line = try JSONSerialization.jsonObject(with: Data(queued("invented-command", at: 95).utf8))
      as! [String: Any]
    line["uuid"] = "invented-attachment"
    return try json(line)
  }
  func testDeletedQueuedInstructionCannotReturnFromContinuedAttachmentOrCopy() throws {
    let parent = try file(.claude, name: "invented-parent.jsonl")
    let attachment = try continuedAttachment()
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([enqueue("invented-command", at: 90), attachment, copy], to: parent)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [95])
    let preview = try store.previewDeletion(in: TimeRange(85, 97))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let child = try file(.claude, name: "invented-child.jsonl")
    try write([attachment, copy], to: child)
    try task.scan(at: 201)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
    XCTAssertEqual(task.health.refused, 3)
    let onlyCopy = try file(.claude, name: "invented-copy-only.jsonl")
    try write([copy], to: onlyCopy)
    try task.scan(at: 202)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
  }
  func testPausedQueuedInstructionCannotReturnFromContinuedAttachmentOrCopy() throws {
    try store.saveFixtureSettings(StorageSettings(pausedUntil: 93, subscriptionConnected: true), at: 85)
    let parent = try file(.claude, name: "invented-parent.jsonl")
    let attachment = try continuedAttachment()
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([enqueue("invented-command", at: 90), attachment, copy], to: parent)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.refused, 2)
    let child = try file(.claude, name: "invented-child.jsonl")
    try write([attachment, copy], to: child)
    try task.scan(at: 201)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
    XCTAssertEqual(task.health.refused, 4)
  }
  func testOffRefusalPersistsNativeIDsAndCopyAliases() throws {
    var settings = StorageSettings(subscriptionConnected: true)
    settings.recordingEnabled = false
    try store.saveFixtureSettings(settings, at: 0)
    var state = AgentLogState()
    _ = parsed(try enqueue("invented-off", at: 90), state: &state)
    let row = try parsedPrompt(queuedCopy("invented-copy-off", at: 96), state: &state)
    let result = try store.appendLogBatch([row], position: LogPosition(
      path: "off", device: 1, inode: 1, offset: 1, state: "{}", seenAt: 200))
    XCTAssertEqual(result.refused, 1)
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 94)
    for id in [row.sourceID!, "claude:invented-copy-off"] {
      XCTAssertEqual(try store.appendEvidence([EvidenceText(ts: 95, kind: .prompt,
        source: "invented-child", sourceID: id, text: "Invented")]).stored, 0)
    }
  }
  func testRetentionRefusalIsNotRememberedSoLongerRetentionTakesItLater() throws {
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true, promptRetentionDays: 1), at: 0)
    var state = AgentLogState()
    let row = try parsedPrompt(queuedCopy("invented-old", at: 96), state: &state)
    func append(path: String) throws -> AppendResult {
      try store.appendLogBatch([row], position: LogPosition(
        path: path, device: 1, inode: 1, offset: 1, state: "{}", seenAt: 100000))
    }
    XCTAssertEqual(try append(path: "first").refused, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true, promptRetentionDays: 30), at: 1)
    XCTAssertEqual(try append(path: "again").stored, 1)
  }
  func testCopyReadBeforeItsPairingParentKeepsOneInstruction() throws {
    let child = try file(.claude, name: "aa-invented-child.jsonl")
    let parent = try file(.claude, name: "zz-invented-parent.jsonl")
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([copy], to: child)
    try write([enqueue("invented-command", at: 90), copy], to: parent)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).map(\.sourceID), ["claude:invented-command"])
  }
  func testEnqueueAndCopyOnlyKeepOneInstructionAcrossSourcesAndReopen() throws {
    let parent = try file(.claude, name: "invented-parent.jsonl")
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([enqueue("invented-command", at: 90), copy], to: parent)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).map(\.sourceID), ["claude:invented-command"])
    let child = try file(.claude, name: "invented-child.jsonl")
    try write([copy], to: child)
    let reopened = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try AgentLogTask(reader: reader(.claude), storage: reopened).scan(at: 201)
    XCTAssertEqual(try reopened.evidence(in: all).count, 1)
    XCTAssertEqual(try reopened.connection.integer(
      "SELECT count(*) FROM forgotten_sources WHERE source_id='claude:invented-copy'"), 0)
  }
  func testDeletedCopyKeepsItsLaterParentRefused() throws {
    let child = try file(.claude, name: "aa-invented-child.jsonl")
    let parent = try file(.claude, name: "zz-invented-parent.jsonl")
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([copy], to: child)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [96])
    let preview = try store.previewDeletion(in: TimeRange(95, 97))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    try write([enqueue("invented-command", at: 90), copy], to: parent)
    try task.scan(at: 201)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
  }
  func testRefusedThroughDeletedCopyRemembersTheInstructionForItsAttachment() throws {
    let child = try file(.claude, name: "aa-invented-child.jsonl")
    let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
    try write([copy], to: child)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    let preview = try store.previewDeletion(in: TimeRange(95, 97))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let parent = try file(.claude, name: "bb-invented-parent.jsonl")
    try write([enqueue("invented-command", at: 90), copy], to: parent)
    try task.scan(at: 201)
    let delivered = try file(.claude, name: "cc-invented-delivered.jsonl")
    try write([enqueue("invented-command", at: 90), continuedAttachment()], to: delivered)
    try task.scan(at: 202)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
  }
  func testTooOldAndPrivateInstructionStaysRefusedForItsCopy() throws {
    for mode in ["pause", "off", "deleted"] {
      if mode != "pause" {
        try tearDownWithError()
        try setUpWithError()
      }
      var settings = StorageSettings(subscriptionConnected: true, promptRetentionDays: 1)
      if mode == "pause" { settings.pausedUntil = 93 }
      if mode == "off" { settings.recordingEnabled = false }
      try store.saveFixtureSettings(settings, at: 85)
      if mode == "off" {
        try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true, promptRetentionDays: 1), at: 93)
      }
      if mode == "deleted" {
        let preview = try store.previewDeletion(in: TimeRange(85, 92))
        _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      }
      let parent = try file(.claude, name: "aa-invented-parent.jsonl")
      let child = try file(.claude, name: "zz-invented-child.jsonl")
      let copy = try queuedCopy("invented-copy", at: 96, commandID: "invented-command")
      try write([enqueue("invented-command", at: 90), copy], to: parent)
      try write([copy], to: child)
      try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 86493)
      XCTAssertEqual(try store.evidence(in: all).count, 0, mode)
    }
  }
  func testContinuedSessionReadFirstUsesDeliveryTime() throws {
    let child = try file(.claude, name: "aa-invented-child.jsonl")
    let parent = try file(.claude, name: "zz-invented-parent.jsonl")
    let lines = try [continuedAttachment(), queuedCopy("invented-copy", at: 96, commandID: "invented-command")]
    try write(lines, to: child)
    try write([enqueue("invented-command", at: 90)] + lines, to: parent)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [95])
  }
  func testRangeRefusedNativeInstructionCannotReturnAtAnotherTime() throws {
    let preview = try store.previewDeletion(in: TimeRange(85, 92))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let row = EvidenceText(ts: 90, kind: .prompt, source: "invented-parent",
      sourceID: "claude:invented-range", text: "Invented")
    XCTAssertEqual(try store.appendEvidence([row]).refused, 1)
    var copy = row
    copy.ts = 95
    copy.source = "invented-child"
    XCTAssertEqual(try store.appendEvidence([copy]).refused, 1)
  }
  func testAliasAndPrivacyRefusalRollBackWithPosition() throws {
    var state = AgentLogState()
    _ = parsed(try enqueue("invented-command", at: 90), state: &state)
    let row = try parsedPrompt(queuedCopy("invented-copy", at: 96, commandID: "invented-command"), state: &state)
    try store.saveFixtureSettings(StorageSettings(pausedUntil: 93, subscriptionConnected: true), at: 85)
    XCTAssertThrowsError(try store.appendLogBatch([row], position: LogPosition(
      path: "invented", device: 1, inode: 1, offset: -1, state: "{}", seenAt: 200)))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    XCTAssertNil(try store.logPosition(path: "invented"))
  }
  func testPreviousSchemaAdoptsIDIndexesWithoutChangingRowsOrPrivacyHistory() throws {
    try store.appendEvidence([EvidenceText(ts: 90, kind: .prompt, source: "invented-parent",
      sourceID: "claude:invented-adopted", text: "Invented")])
    let history = try store.logRecordingHistory()
    let settings = try store.settings()
    try makeMainLogOrigin(store)
    for version in [1, 2, 9] {
      try store.connection.run("DROP INDEX IF EXISTS evidence_prompt_id")
      try store.connection.run("DROP INDEX IF EXISTS forgotten_source_id")
      try store.connection.run("PRAGMA user_version=\(version)")
      if version != 9 {
        XCTAssertThrowsError(try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root)))
        XCTAssertEqual(try store.evidence(in: all).count, 1)
        XCTAssertEqual(try store.logRecordingHistory(), history)
        XCTAssertEqual(try store.settings(), settings)
        continue
      }
      let adopted = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      XCTAssertEqual(try adopted.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
      XCTAssertEqual(try adopted.evidence(in: all).count, 1)
      XCTAssertEqual(try adopted.logRecordingHistory(), history)
      XCTAssertEqual(try adopted.settings(), settings)
      for (sql, index) in [
        ("SELECT 1 FROM evidence WHERE kind='prompt' AND source_id='claude:invented-adopted'",
          "evidence_prompt_id (source_id=?)"),
        ("SELECT 1 FROM forgotten_sources WHERE source_id='claude:invented-copy'",
          "forgotten_source_id (source_id=?)"),
      ] {
        var plans: [String] = []
        try adopted.connection.namedRows("EXPLAIN QUERY PLAN " + sql) { plans.append(try $0.text("detail")) }
        XCTAssertTrue(plans.joined().contains(index))
      }
    }
  }
  func testOwnWindowRejectsRelativeFolderAndStandardizesParentComponents() {
    XCTAssertFalse(AgentWindowIdentity.containsWorkingFolder("invented/" + AgentWindowIdentity.relativeFolder))
    XCTAssertFalse(AgentWindowIdentity.containsWorkingFolder(
      "/invented/home/" + AgentWindowIdentity.relativeFolder + "/../other"))
  }
  func testHumanQueuedAttachmentWrapperIsTrimmedAndCounted() throws {
    var state = AgentLogState()
    guard case .excluded(.taskNotification) = parsed(try queued("invented", at: 95,
      fields: ["prompt": " \n<task-notification>Invented"]), state: &state)
    else { return XCTFail("Human-marked attachment still carries the tool wrapper") }
    guard case .excluded(.localCommandOutput) = parsed(try claudeRow([
      "message": ["content": "\n <local-command-stdout>Invented"]]), state: &state)
    else { return XCTFail("User wrapper prefix is tested after leading whitespace") }
  }
  func testExcludedUserKeepsDeliveredQueueForItsCopy() throws {
    var state = AgentLogState()
    _ = try parsedPrompt(queued("invented-delivered", at: 90), state: &state)
    _ = parsed(try claudeRow(["isMeta": true,
      "message": ["content": "Invented repeated queue words"]], at: 95), state: &state)
    XCTAssertEqual(state.queued.filter(\.delivered).count, 0)
    XCTAssertEqual(try parsedPrompt(queuedCopy("invented-copy", at: 96, commandID: "invented-command"), state: &state).sourceID,
      "claude:invented-command")
  }
  func testMarkedOrWrappedEnqueueNeverEntersPendingState() throws {
    for fields: [String: Any] in [["isMeta": true], ["content": "<task-notification>Invented"]] {
      var state = AgentLogState()
      var line = try JSONSerialization.jsonObject(with: Data(enqueue("invented", at: 90).utf8)) as! [String: Any]
      for (key, value) in fields { line[key] = value }
      guard case .ignored = parsed(try json(line), state: &state) else { return XCTFail("Not a prompt") }
      XCTAssertTrue(state.queued.isEmpty)
    }
  }
  func testWhitespaceOnlyPromptCountsAsEmpty() throws {
    var state = AgentLogState()
    guard case .excluded(.empty) = parsed(try claudeRow([
      "message": ["content": " \t\n "]]), state: &state)
    else { return XCTFail("Whitespace-only prompt must count as empty") }
  }
}
