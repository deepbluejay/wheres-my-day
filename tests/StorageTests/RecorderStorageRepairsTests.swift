import Core
import Foundation
import XCTest

@testable import Storage

extension StorageTests {
  func testGeneralEvidenceAndLogBatchRefuseScreenAndContinue() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let screen = EvidenceText(
      ts: 61, kind: .screen, source: "invented-screen",
      text: "Invented raw screen")
    let prompt = EvidenceText(
      ts: 62, kind: .prompt, source: "invented-prompt", sourceID: "one", text: "Invented prompt")
    XCTAssertEqual(try store.appendEvidence([screen, prompt]), AppendResult(stored: 1, refused: 1))
    let next = EvidenceText(ts: 63, kind: .prompt, source: "invented-prompt", sourceID: "two", text: "Invented prompt")
    let position = LogPosition(path: "invented-log", device: 1, inode: 2, offset: 30, seenAt: 63)
    XCTAssertEqual(try store.appendLogBatch([screen, next], position: position), AppendResult(stored: 1, refused: 1))
    XCTAssertEqual(try store.logPosition(path: "invented-log"), position)
    XCTAssertEqual(try store.evidence(in: all), [prompt, next])
  }
  func testKnownCaptureStillRequiresOccurrenceWrite() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), busyMilliseconds: 0, databaseScope: .directory(folder))
    let blocker = try SQLiteConnection(url: url, scope: .directory(folder), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    defer { try? blocker.run("ROLLBACK") }
    XCTAssertThrowsError(try store.appendScreenCapture(
      text: "password=inventedCredential", at: 10,
      source: "invented", knownKeys: ["secret"]))
  }
  func testCaptureDuplicateAndRebuildLatestStoredTime() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let result = try store.appendScreenCapture(
      text: "Invented line 1\nInvented line 2\nAnother line", at: 10,
      source: "invented", documentKey: "invented-document", project: "invented-project", knownKeys: [])
    XCTAssertEqual(result.addedKeys, ["Inventedline", "Anotherline"])
    XCTAssertEqual(try store.evidence(in: all).first?.text, "Invented line 1\nInvented line 2\nAnother line")
    XCTAssertEqual(try store.evidence(in: all).first?.documentKey, "invented-document")
    XCTAssertEqual(try store.evidence(in: all).first?.project, "invented-project")
    try store.appendScreenCapture(text: "Invented line 3", at: 20, source: "invented", knownKeys: [])
    XCTAssertEqual(try store.recentScreenLineKeys(at: 3610), [:])
    XCTAssertEqual(try store.recentScreenLineKeys(at: 3620), [:])
  }
  func testWholeCaptureStoredAndNovelViewMaskedAgain() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let label = "Authorization: Bearer"
    let known = "Invented separator line"
    let value = "INVENTEDVALUEabcdefghijklmnopqrst"
    let capture = [label, known, value].joined(separator: "\n")
    XCTAssertEqual(Redaction.apply(capture).text, capture)
    let selected = ScreenLines.select(maskedText: capture, knownKeys: [ScreenLineKey.fromMaskedLine(known)])
    let expected = Redaction.apply(selected.lines.joined(separator: "\n")).text
    XCTAssertFalse(expected.contains(value))
    try store.appendScreenCapture(text: capture, at: 10, source: "invented", knownKeys: [ScreenLineKey.fromMaskedLine(known)])
    XCTAssertEqual(try store.evidence(in: all).first?.text, Redaction.apply(capture).text)
    XCTAssertEqual(try store.novelEvidence(in: all).first?.text, Redaction.apply(ScreenLines.select(maskedText: capture, knownKeys: []).lines.joined(separator: "\n")).text)
  }

  func testLogBatchPositionStateIsMaskedBeforeBinding() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let raw = "password=inventedPositionSecret"
    let position = LogPosition(path: "invented-log", device: 1, inode: 2, offset: 3, state: raw, seenAt: 10)
    try store.appendLogBatch([], position: position)
    let state = try XCTUnwrap(store.logPosition(path: position.path)).state
    XCTAssertEqual(state, Redaction.apply(raw).text)
    XCTAssertFalse(state.contains("inventedPositionSecret"))
  }

}
