import Core
import Foundation
@testable import Storage
import XCTest

extension StorageTests {
  func testMachineIdentitiesKeepOldMaskingAndDeletionScope() throws {
    let ids = ["01234567-89ab-cdef-0123-456789abcdef", "fedcba98-7654-3210-fedc-ba9876543210"]
    let sources = ids.map { "rollout-2026-10-14T08-25-39-" + $0 }
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let rows = sources.enumerated().map { index, source in
      EvidenceText(ts: 60 + index, kind: .prompt, source: source,
        sourceID: "codex:" + ids[index] + ":" + ids[1-index] + ":" + ids[index], text: "invented instruction")
    }
    XCTAssertEqual(try store.appendEvidence(rows), AppendResult(stored: 2))
    XCTAssertEqual(try store.evidence(in: all).map(\.source), sources)
    XCTAssertEqual(try store.evidence(in: all).map(\.sourceID), rows.map(\.sourceID))
    XCTAssertEqual(try store.appendEvidence(rows), AppendResult(refused: 2))
    try store.appendSamples([TimeSample(ts: 62, bundleID: "com.invented.aB7xQ2pL9mR4zT6v")])
    XCTAssertEqual(try store.samples(in: all).first?.bundleID, "com.invented.aB7xQ2pL9mR4zT6v")
    let preview = try store.previewDeletion(in: TimeRange(60, 61))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.appendEvidence(rows), AppendResult(refused: 2))
    XCTAssertEqual(try store.evidence(in: all).map(\.source), [sources[1]])
    let identity = "password: invented"
    try store.connection.run("INSERT INTO forgotten_sources VALUES(?,?)", [.key(identity), .key("other")])
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source=?", [.key(identity)]), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources WHERE source='[secret]'"), 1)
  }

  func testOldCheckpointDerivesOwnFolderBeforeMaskingAndKeepsIDs() throws {
    let project = "/invented/Library/Application Support/ActivityProbe/agent-window"
    let id = "01234567-89ab-cdef-0123-456789abcdef"
    let old = String(decoding: try JSONSerialization.data(withJSONObject: [
      "session": id, "project": project, "metadataRead": true,
      "queued": [["hash": "invented", "id": "claude:" + id, "ts": 90, "delivered": true]]
    ]), as: UTF8.self)
    XCTAssertEqual(try AgentLogState.decode(old).ownWorkingFolder, true)
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let path = "/invented/rollout-2026-10-14T08-25-39-" + id + ".jsonl"
    try store.appendLogBatch([], position: LogPosition(path: path, device: 1, inode: 2, offset: 123, state: old, seenAt: 100))
    let position = try XCTUnwrap(try store.logPosition(path: path))
    XCTAssertEqual(position.path, Redaction.applyKnownSecrets(path).text)
    let restored = try AgentLogState.decode(position.state)
    XCTAssertEqual(restored.session, id)
    XCTAssertEqual(restored.ownWorkingFolder, true)
    let text = "{\"type\":\"user\",\"timestamp\":\"1970-01-01T00:01:41Z\",\"uuid\":\"invented\",\"message\":{\"role\":\"user\",\"content\":\"invented instruction\"}}"
    var state = restored
    guard case .excluded(.ownWindow) = AgentLogParser.parse(text, tool: .claude, file: path, state: &state, fingerprint: { $0 }) else {
      return XCTFail("Old own-window checkpoint was accepted")
    }
  }
}
