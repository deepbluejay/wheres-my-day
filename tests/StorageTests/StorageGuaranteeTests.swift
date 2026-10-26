import Core
@testable import Storage
import Foundation
import XCTest

extension StorageTests {
  func testDeletionKeepsLogPosition() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let position = LogPosition(path: "invented-log", device: 1, inode: 1, offset: 99, seenAt: 61)
    try store.saveLogPosition(position)
    try store.appendSamples([TimeSample(ts: 61)])
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.logPosition(path: position.path), position)
  }

  func testRetentionKeepsLogPosition() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let position = LogPosition(path: "invented-log", device: 1, inode: 1, offset: 99, seenAt: 1)
    try store.saveLogPosition(position)
    try store.appendFixtureEvidence([EvidenceText(ts: 1, kind: .prompt, source: "invented", text: "expired")])
    XCTAssertEqual(try store.cleanRetention(at: 31 * 86400), 1)
    XCTAssertEqual(try store.logPosition(path: position.path), position)
  }

  func testConfirmationIncludesContentWithSameRowCount() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: .screen, source: "invented", text: "first")])
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.connection.run("UPDATE collection_blobs SET content='later' WHERE hash IN (SELECT text_hash FROM screen_payloads)")
    XCTAssertEqual(try store.previewDeletion(in: preview.range).counts, preview.counts)
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.evidence(in: all).first?.text, "later")
  }

  func testDeleteRequiresOver24HourAllowanceAgain() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.appendSamples([TimeSample(ts: 61)])
    let preview = try store.previewDeletion(in: TimeRange(0, 86401), allowOver24Hours: true)
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.samples(in: all).count, 1)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation, allowOver24Hours: true)
  }

  func testDelayedIntervalsAreRefusedWholeAndCounted() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let result = try store.appendIntervals([
      NamedInterval(range: TimeRange(0, 180), kind: .work),
      NamedInterval(range: TimeRange(180, 240), kind: .personal)])
    XCTAssertEqual(result, AppendResult(stored: 1, refused: 1))
    XCTAssertEqual(try store.intervals(in: all).map(\.range), [TimeRange(180, 240)])
  }

  func testContentFreeModelCallsSurviveDeletionAndDelayedWrites() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let call = ModelCall(ts: 90, range: TimeRange(0, 3600), model: "invented", succeeded: false)
    try store.appendModelCall(call)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertNil(preview.counts["model_calls"])
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.modelCalls(in: all), [call])
    XCTAssertEqual(try store.appendModelCall(call), AppendResult(stored: 1))
    XCTAssertEqual(try store.modelCalls(in: all), [call, call])
    XCTAssertEqual(try store.intervals(in: all), [])
    XCTAssertEqual(try store.appendIntervals([NamedInterval(range: TimeRange(120, 180), kind: .work)]).stored, 1)
  }

  func testSecureDeleteOnEveryConnection() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)), second = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    for connection in [store.connection, second.connection] {
      XCTAssertEqual(try connection.integer("PRAGMA secure_delete"), 1)
    }
  }

  func testExcludedSampleLosesWindowAndDocumentKey() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.appendSamples([TimeSample(ts: 61, app: "Invented app", window: "Invented private text",
      documentKey: "invented-private-document", excluded: true)])
    let sample = try XCTUnwrap(store.samples(in: all).first)
    XCTAssertEqual(sample.app, "Invented app")
    XCTAssertEqual(sample.window, "")
    XCTAssertEqual(sample.documentKey, "")
  }

  func testDeletionFailureRollsBackEverything() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let settings = StorageSettings(recordingEnabled: false)
    try store.appendSamples([TimeSample(ts: 61)])
    try store.saveSettings(settings)
    try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: .prompt, source: "invented", sourceID: "one", text: "kept")])
    try store.appendIntervals([NamedInterval(range: TimeRange(60, 120), kind: .work)])
    try store.connection.run("""
      CREATE TRIGGER fail_deletion BEFORE DELETE ON intervals
      BEGIN SELECT RAISE(ABORT,'invented failure'); END
      """)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.samples(in: all).count, 1)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.intervals(in: all).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_ranges"), 0)
    XCTAssertEqual(try store.settings(), settings)
  }

  func testDeletionTruncatesWALWithoutSnapshotReader() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let marker = "INVENTED_DELETION_MARKER_ABCXYZ"
    try store.appendSamples([TimeSample(ts: 61, window: marker)])
    try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: .screen, source: "invented", text: marker)])
    try store.appendIntervals([NamedInterval(range: TimeRange(60, 120), name: marker, kind: .work)])
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    let result = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertTrue(result.walTruncated)
    for path in [url.path, url.path + "-wal"] {
      let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
      XCTAssertNil(bytes.range(of: Data(marker.utf8)))
    }
  }

  func testEmptyDeletionLeavesForgottenMarkAndCountsDelayedContent() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_ranges"), 1)
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 61), TimeSample(ts: 121)]),
      AppendResult(stored: 1, refused: 1))
    XCTAssertEqual(try store.appendFixtureEvidence([
      EvidenceText(ts: 61, kind: .screen, source: "invented", text: "refused"),
      EvidenceText(ts: 121, kind: .screen, source: "invented", text: "stored")]),
      AppendResult(stored: 1, refused: 1))
  }

  func testReaderReplaysFileWithoutDuplicatePrompts() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let prompts = (0..<3).map {
      EvidenceText(ts: 60 + $0, kind: .prompt, source: "invented-file", sourceID: "row-\($0)", text: "prompt \($0)")
    }
    let position = LogPosition(path: "invented-file", device: 1, inode: 1, offset: 100, seenAt: 70)
    XCTAssertEqual(try store.appendLogBatch(prompts, position: position), AppendResult(stored: 3))
    XCTAssertEqual(try store.appendLogBatch(prompts, position: position), AppendResult(refused: 3))
    XCTAssertEqual(try store.evidence(in: all), prompts)
    XCTAssertEqual(try store.appendFixtureEvidence([
      EvidenceText(ts: 90, kind: .prompt, source: "another-file", sourceID: "row-0", text: "other")]).stored, 1)
  }

  func testLookupKeysRetainIdentityAndValuesAreMasked() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    for (offset, key) in ["rollout-2026-10-14T08-25-39-01234567-89ab-cdef-0123-456789abcdef", "rollout-2026-10-14T08-25-39-fedcba98-7654-3210-fedc-ba9876543210"].enumerated() {
      try store.saveLogPosition(LogPosition(path: key, device: 1, inode: 1, offset: offset, state: secret, seenAt: 60))
      XCTAssertEqual(try store.logPosition(path: key)?.offset, offset)
      XCTAssertEqual(try store.logPosition(path: key)?.state, "[secret]")
    }
    XCTAssertEqual(try store.logPosition(path: "rollout-2026-10-14T08-25-39-01234567-89ab-cdef-0123-456789abcdef")?.offset, 0)
    try store.saveSettings(StorageSettings(general: ["invented.One-1": secret, "invented_Two": secret]))
    XCTAssertEqual(try store.settings().general, ["invented.One-1": "[secret]", "invented_Two": "[secret]"])
    for key in ["password=inventedOne", "invented space", "한글", "", "newline\n"] {
      XCTAssertThrowsError(try store.saveSettings(StorageSettings(general: [key: secret])))
    }
    XCTAssertEqual(try store.settings().general.count, 2)
  }

  func testExistingOpenAvoidsWriteLockAndUsesRequestedBusyWait() throws {
    let writer = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try writer.connection.transaction {
      let started = Date()
      let reader = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), busyMilliseconds: 50, databaseScope: .directory(folder))
      XCTAssertLessThan(Date().timeIntervalSince(started), 1)
      XCTAssertEqual(try reader.connection.integer("PRAGMA busy_timeout"), 50)
      let writeStarted = Date()
      XCTAssertThrowsError(try reader.appendSamples([TimeSample(ts: 61)])) { error in
        guard case StorageError.busy = error else { return XCTFail("Expected busy, got \(error)") }
      }
      XCTAssertLessThan(Date().timeIntervalSince(writeStarted), 1)
    }
  }

  func testMalformedGeneralKeyKeepsOtherKeysAndRecordingIsIndependentOfPause() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let file = folder.appendingPathComponent("invented-general.json")
    let bytes = Data(#"{"outputLanguage":"ko","dayStartHour":"wrong"}"#.utf8)
    try bytes.write(to: file)
    try store.importOldSettings(privacyFile: folder.appendingPathComponent("missing.json"), generalFile: file)
    XCTAssertEqual(try store.settings().general, ["outputLanguage": "ko"])
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    let settings = StorageSettings(pausedUntil: 999, recordingEnabled: false)
    try store.saveSettings(settings)
    XCTAssertEqual(try store.settings(), settings)
  }
}
