import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension AgentLogTests {
  func testProcessListingFailureStillImportsDefaultRootAndReportsDiscoveryFailure() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "default")], to: url)
    processes.listingFails = true
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    XCTAssertThrowsError(try task.scan(at: 200))
    XCTAssertEqual(try eventCount(), 1)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.discoveryFailures, 1)
    XCTAssertEqual(task.health.folderFailures, 0)
    XCTAssertEqual(task.health.lastErrorKind, .process)
    XCTAssertTrue(processes.requested.isEmpty)
  }
  func testOffAndPauseAvoidDiscoveryWhileDisconnectedRecordingWorks() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "default")], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: 0)
    try task.scan(at: 200)
    try store.saveSettings(StorageSettings(pausedUntil: 500), at: 0)
    try task.scan(at: 200)
    XCTAssertEqual(processes.listings, 0)
    XCTAssertNil(try store.logPosition(path: url.path))
  }
  func testImportedAndDelegatedCodexEventsCarrySessionOrigin() throws {
    let url = try file(.codex)
    try write([json(["type": "session_meta", "timestamp": stamp(90),
      "payload": ["id": "invented-thread", "source": "subagent", "parent_thread_id": "invented-parent"]]),
      codexRow(["turn_id": "external-import-turn-invented"]),
      json(["type": "assistant", "timestamp": stamp(101)])], to: url)
    try AgentLogTask(reader: reader(.codex), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 3)
    XCTAssertEqual(try eventCount("flags LIKE '%sessionOrigin:subagent%'"), 3)
    XCTAssertEqual(try eventCount("flags LIKE '%imported%'"), 1)
    XCTAssertEqual(try store.evidence(in: all), [])
  }
  func testEscapedSecretsAreDecodedBeforeMasking() throws {
    let url = try file(.claude)
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let escaped = secret.map { String(format: "\\u%04x", $0.asciiValue!) }.joined()
    let row = "{\"cwd\":\"/invented/project\",\"type\":\"assistant\",\"timestamp\":100,\"content\":\"" + escaped + "\"}"
    try write([row], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    var payload = ""
    try store.connection.namedRows("SELECT payload FROM agent_log_payloads") { payload = try $0.text("payload") }
    XCTAssertTrue(payload.contains("[secret]"))
    XCTAssertFalse(payload.contains(secret))
    XCTAssertFalse(payload.contains(escaped))
  }
  func eventCount(_ clause: String = "1") throws -> Int {
    try store.connection.integer("SELECT count(*) FROM agent_log_events WHERE " + clause)
  }
  func testAllRolesAndOrderedBlocksRemainLocalAndMasked() throws {
    let url = try file(.claude)
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let blocks: [[String: Any]] = [["type": "text", "text": "Invented text"],
      ["type": "image", "source": ["path": "/invented/image", "password": "invented-private"]],
      ["type": "future", "text": secret], ["type": "tool_result", "content": "Invented result"]]
    try write(try ["user", "assistant", "tool", "system", "future"].map { role in
      try json(["type": role, "timestamp": stamp(100), "uuid": role, "cwd": "/invented/project",
        "message": ["role": role, "content": blocks]])
    }, to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try eventCount(), 5)
    XCTAssertEqual(try store.evidence(in: all).count, 0)
    var payloads: [String] = []
    try store.connection.namedRows("SELECT payload FROM agent_log_payloads") { payloads.append(try $0.text("payload")) }
    for text in payloads {
      XCTAssertFalse(text.contains(secret))
      XCTAssertFalse(text.contains("invented-private"))
      let row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
      let message = row["message"] as! [String: Any]
      XCTAssertEqual((message["content"] as! [[String: Any]]).compactMap { $0["type"] as? String }, ["text", "image", "future", "tool_result"])
    }
    XCTAssertEqual(task.health.acquiredEvents, 5)
    for suffix in ["", "-wal"] {
      let bytes = (try? Data(contentsOf: root.appendingPathComponent("invented.sqlite" + suffix))) ?? Data()
      XCTAssertNil(bytes.range(of: Data(secret.utf8)))
      XCTAssertNil(bytes.range(of: Data("invented-private".utf8)))
    }
  }
  func testMalformedNumericAndUnknownTimeRecordsSurviveWithNoInventedPrompt() throws {
    let url = try file(.claude)
    try write(["not JSON api_key=invented-secret", "[]", "{}",
      json(["type": "assistant", "timestamp": 100, "cwd": "/invented/project", "message": ["content": "Invented numeric time"]]),
      json(["type": "tool", "timestamp": "100"]),
      json(["type": "future", "timestamp": "unknown"])], to: url)
    try append(Data([0xff, 0xfe, 10]), to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(try eventCount(), 7)
    XCTAssertEqual(try eventCount("timestamp_known=0"), 5)
    XCTAssertEqual(try eventCount("parse_status='invalidUTF8'"), 1)
    XCTAssertEqual(try store.evidence(in: all), [])
    try task.scan(at: 300)
    XCTAssertEqual(try eventCount(), 7)
  }
  func testOversizeAndBlankRecordsHaveExplicitOccurrences() throws {
    let url = try file(.claude)
    let prefix = Data("Invented safe prefix api_key=invented-secret ".utf8)
    let huge = Data((try meta(.claude) + "\n").utf8) + prefix + Data(repeating: 120, count: AgentLogFiles.longestLineBytes + 1) + Data([10, 10])
    try huge.write(to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 3)
    XCTAssertEqual(try eventCount("parse_status='truncated'"), 1)
    XCTAssertEqual(try store.evidence(in: all), [])
    var payload = ""
    try store.connection.namedRows("SELECT payload FROM agent_log_payloads WHERE payload LIKE '%truncated%'") { payload = try $0.text("payload") }
    XCTAssertTrue(payload.contains("Invented safe prefix"))
    XCTAssertFalse(payload.contains("invented-secret"))
    XCTAssertLessThanOrEqual(payload.utf8.count, AgentLogFiles.longestLineBytes + 20)
  }
  func testEmptyAndWhitespaceEventsPreserveStructureWithoutPrompt() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "blank", text: " \n "),
      json(["type": "user", "timestamp": stamp(101), "message": ["content": []]])], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 2)
    XCTAssertEqual(try store.evidence(in: all), [])
  }
  func testMarkedAndUncertainOriginsAreOccurrences() throws {
    let url = try file(.claude)
    try write([claudeRow(["isMeta": true, "origin": ["kind": "peer"]]),
      queued("one", at: 101, fields: ["humanTurn": false]),
      queued("two", at: 102, fields: ["humanTurn": NSNull()]),
      claudeRow(["promptSource": "sdk"]),
      claudeRow(["message": ["content": "<bash-stdout>Invented literal wrapper"]])], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 5)
    XCTAssertEqual(try eventCount("flags LIKE '%isMeta%'"), 1)
    XCTAssertEqual(try eventCount("flags LIKE '%humanTurn%'"), 2)
    XCTAssertEqual(try store.evidence(in: all), [])
  }
  func testIdenticalMissingIDsAndBackwardClockRemainDistinct() throws {
    let url = try file(.claude)
    let row = try json(["type": "user", "timestamp": stamp(100), "message": ["content": "Invented same words"]])
    try write([row, row, enqueue("explicit", at: 110), queued("explicit", at: 90), queuedCopy("different", at: 80)], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 5)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [80, 90, 100, 100])
    XCTAssertEqual(try store.evidence(in: all).filter { $0.ts == 100 }.count, 2)
  }
  func testNativeCopiesKeepOccurrencesButCanonicalPromptIsStoredOnce() throws {
    for name in ["invented-original.jsonl", "invented-copy.jsonl"] {
      try write([prompt(.claude, id: "same-native-id")], to: file(.claude, name: name))
    }
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 2)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
  }
  func testCodexCopiesKeepSourceOccurrencesAndOneCanonicalPrompt() throws {
    for name in ["invented-first.jsonl", "invented-copy.jsonl"] {
      try write([meta(.codex), prompt(.codex, id: "same-native-id")], to: file(.codex, name: name))
    }
    try AgentLogTask(reader: reader(.codex), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 4)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
  }
  func testSuccessfulAliasSurvivesRetentionWithoutBecomingPrivacyRefusal() throws {
    let original = EvidenceText(ts: 100, kind: .prompt, source: "invented-original",
      sourceID: "claude:canonical", sourceAliases: ["claude:copy"], text: "Invented words")
    XCTAssertEqual(try store.appendEvidence([original]).stored, 1)
    _ = try store.cleanRetention(at: 31 * 86400)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    let copy = EvidenceText(ts: 200, kind: .prompt, source: "invented-copy",
      sourceID: "claude:copy", text: "Invented words")
    XCTAssertEqual(try store.appendEvidence([copy]).stored, 1)
    XCTAssertEqual(try store.evidence(in: all).first?.sourceID, "claude:canonical")
  }
  func testDeletionPreviewIncludesPayloadAndIdentityBytes() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "one")], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    try store.connection.run("UPDATE agent_log_payloads SET payload='invented changed payload'")
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try eventCount(), 1)
  }
  func testEventForgetAndRetentionRemovePayloadAndPreventCopiedResurrection() throws {
    let url = try file(.claude)
    try write([json(["type": "assistant", "timestamp": stamp(100), "uuid": "deleted", "cwd": "/invented/project", "message": ["content": "Invented answer"]])], to: url)
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    XCTAssertEqual(preview.counts["agent_log_events"], 1)
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_event_identities"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
    try write([json(["type": "assistant", "timestamp": stamp(150), "uuid": "deleted", "cwd": "/invented/project"])], to: file(.claude, name: "invented-later-copy.jsonl"))
    try task.scan(at: 300)
    XCTAssertEqual(try eventCount(), 0)
    try write([prompt(.claude, id: "retention", at: 200)], to: file(.claude, name: "invented-retention.jsonl"))
    try task.scan(at: 300)
    _ = try store.cleanRetention(at: 31 * 86400)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_event_identities"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
  }
  func testHistoricalPrivacyRefusesAllRolesAndUnknownTime() throws {
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: 90)
    try store.saveSettings(StorageSettings(), at: 110)
    let url = try file(.claude)
    try write([json(["type": "assistant", "uuid": "off", "timestamp": stamp(100), "cwd": "/invented/project"]),
      json(["type": "assistant", "uuid": "unknown"]),
      json(["type": "assistant", "uuid": "allowed", "timestamp": stamp(120)])], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_refusals"), 2)
  }
  func testOwnSessionProtectsEveryRole() throws {
    let url = try file(.codex)
    try write([json(["type": "session_meta", "timestamp": stamp(100),
      "payload": ["originator": AgentWindowIdentity.codexOriginator]]),
      json(["type": "assistant", "timestamp": stamp(101)])], to: url)
    try AgentLogTask(reader: reader(.codex), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 0)
  }
  func testMalformedOwnHeadersStillExcludeFollowingRecords() throws {
    let url = try file(.claude)
    try write([json(["cwd": "/invented/home/" + AgentWindowIdentity.relativeFolder]),
      json(["type": "assistant", "timestamp": stamp(101)]),
      prompt(.claude, id: "own")], to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.evidence(in: all), [])
    let codex = try file(.codex)
    try write([json(["payload": ["originator": AgentWindowIdentity.codexOriginator]]),
      json(["type": "assistant", "timestamp": stamp(101)])], to: codex)
    try AgentLogTask(reader: reader(.codex), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 0)
  }
  func testEventAndCursorRetryAreAtomic() throws {
    let url = try file(.claude)
    try write([prompt(.claude, id: "one")], to: url)
    try store.connection.run("CREATE TRIGGER fail_log_position BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    XCTAssertThrowsError(try task.scan(at: 200))
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_event_identities"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
    try store.connection.run("DROP TRIGGER fail_log_position")
    try task.scan(at: 300)
    XCTAssertEqual(try eventCount(), 1)
  }
}
