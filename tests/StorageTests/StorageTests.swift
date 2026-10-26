import Core
@testable import Storage
import Foundation
import SQLite3
import Darwin
import XCTest

extension ActivityStorage: SummaryStorage {}

final class StorageTests: XCTestCase {
  var folder: URL!
  var url: URL { folder.appendingPathComponent("invented.sqlite") }
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
  let all = TimeRange(0, 1000000)
  let secret = "password=inventedCredential"

  func testBackupExclusionOnOpenAndFailureDoesNotBlockWrites() throws {
    let storage = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertNil(storage.securityHealth.backupExclusionFailure)
    let failed = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), excludeFromBackup: { _ in throw NSError(domain: "invented", code: 1) }, databaseScope: .directory(folder))
    XCTAssertEqual(failed.securityHealth.backupExclusionFailure?.rawValue, "backup_exclusion_failed")
    XCTAssertEqual(try failed.appendSamples([TimeSample(ts: 1, app: "Invented", keys: 1)]).stored, 1)
  }
  func testDatabaseOverrideLeavesUnrelatedFolderInBackups() throws {
    let override = folder.appendingPathComponent("shared", isDirectory: true)
    try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
    try Data("Invented unrelated file".utf8).write(to: override.appendingPathComponent("other"))
    var marks = 0
    let store = try ActivityStorage(url: override.appendingPathComponent("override.sqlite"), appDataDirectory: folder,
      excludeFromBackup: { directory in marks += 1; try ActivityStorage.excludeFromBackup(directory) }, databaseScope: .directory(folder))
    XCTAssertEqual(marks, 0)
    XCTAssertNotEqual(try override.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(getxattr(override.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0), -1)
    XCTAssertEqual(errno, ENOATTR)
    XCTAssertEqual(store.securityHealth.backupExclusionFailure?.rawValue, "backup_exclusion_skipped_override")
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 1, keys: 1)]).stored, 1)
  }
  func testPreviousSchemaAddsTableFactsWithoutRewritingOldCalls() throws {
    let previous = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let old = ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented", succeeded: true)
    try previous.appendModelCall(old)
    try previous.connection.run("ALTER TABLE model_calls DROP COLUMN table_facts")
    try previous.connection.run("PRAGMA user_version=3")
    let adopted = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertEqual(try adopted.modelCalls(in: all), [old])
    let call = ModelCall(ts: 1200, range: TimeRange(600, 1200), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 1200, sentRanges: [TimeRange(600, 900)], endsAtRest: false))
    try adopted.appendModelCall(call)
    XCTAssertEqual(try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)).modelCalls(in: all), [old, call])
    XCTAssertEqual(try adopted.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
  }
  func testDeletingObservationsErasesMinuteFactsButKeepsBillingAndOtherMinutes() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let call = ModelCall(ts: 600, range: TimeRange(0, 360), model: "invented", inputTokens: 12, succeeded: true,
      tableFacts: SummaryCallFacts(through: 600, sentRanges: [TimeRange(0, 360)], endsAtRest: true, activeMinutes: [0, 60]))
    try store.appendModelCall(call)
    let range = TimeRange(60, 180), preview = try store.previewDeletion(in: range)
    _ = try store.deleteRecords(in: range, confirmation: preview.confirmation)
    let saved = try XCTUnwrap(store.modelCalls(in: all).first)
    XCTAssertEqual(saved.inputTokens, 12); XCTAssertEqual(saved.range, call.range)
    XCTAssertEqual(saved.tableFacts?.activeMinutes, [0])
    XCTAssertEqual(saved.tableFacts?.restMinutes, [180, 240, 300])
    XCTAssertEqual(saved.tableFacts?.sentRanges, [TimeRange(0, 60), TimeRange(180, 360)])
  }
  // Ideal: forgetting the whole call removes every inner boundary while retaining billing.
  func testDeletingWholeCallErasesItsSentRangeLayout() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.appendModelCall(ModelCall(ts: 3600, range: TimeRange(0, 3600), model: "invented",
      inputTokens: 12, succeeded: true, tableFacts: SummaryCallFacts(through: 3600,
        sentRanges: [TimeRange(0, 1500), TimeRange(1800, 3300)], endsAtRest: true, activeMinutes: [0, 1800])))
    let range = TimeRange(0, 3600), preview = try store.previewDeletion(in: range)
    _ = try store.deleteRecords(in: range, confirmation: preview.confirmation)
    let call = try XCTUnwrap(store.modelCalls(in: all).first)
    XCTAssertEqual(call.inputTokens, 12)
    XCTAssertEqual(call.tableFacts?.sentRanges, [])
    XCTAssertEqual(call.tableFacts?.activeMinutes, [])
    XCTAssertEqual(call.tableFacts?.restMinutes, [])
  }
  // Ideal: a truncated snapshot uses legacy reconstruction without breaking reads or deletion.
  func testUnreadableTableFactsFallBackToLegacyReconstruction() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.appendSamples([TimeSample(ts: 0, app: "invented", keys: 1)])
    let call = ModelCall(ts: 600, range: TimeRange(0, 360), model: "invented", succeeded: true)
    try store.appendModelCall(call)
    let expected = try SummaryTimeline.minutes(in: TimeRange(0, 600), storage: store)
    try store.connection.run("UPDATE model_calls SET table_facts=?", [.key("{\"through\":")])
    XCTAssertEqual(try store.modelCalls(in: all), [call])
    XCTAssertEqual(try SummaryTimeline.minutes(in: TimeRange(0, 600), storage: store), expected)
    let range = TimeRange(60, 120), preview = try store.previewDeletion(in: range)
    XCTAssertNoThrow(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    XCTAssertEqual(try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)).modelCalls(in: all), [call])
    try store.connection.namedRows("SELECT table_facts FROM model_calls") {
      XCTAssertNil(try $0.optionalText("table_facts"))
    }
  }
  func testRoundTripsAndMaskingEveryTextPath() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let sample = TimeSample(ts: 61, bundleID: secret, app: secret, window: secret, documentKey: secret,
      keys: 3, clicks: 2, scrolls: 1, moved: true, synthetic: 4, keepingAwake: true,
      document: secret, browserAddress: secret)
    try store.appendSamples([sample])
    let got = try XCTUnwrap(store.samples(in: all).first)
    for text in [got.bundleID, got.app, got.window, got.documentKey] { XCTAssertEqual(text, "[secret]") }
    XCTAssertEqual(got.keys, 3); XCTAssertEqual(got.synthetic, 4); XCTAssertTrue(got.keepingAwake); XCTAssertTrue(got.hasInput)
    let observed = try XCTUnwrap(store.observations(in: all).first).sample
    XCTAssertEqual(observed.document, "[secret]")
    XCTAssertEqual(observed.browserAddress, "[secret]")
    try store.appendIntervals([NamedInterval(range: TimeRange(60, 120), name: secret, description: secret, kind: .work, project: secret)])
    let interval = try XCTUnwrap(store.intervals(in: all).first)
    XCTAssertEqual(interval.kind, .work)
    for text in [interval.name, interval.description, interval.project] { XCTAssertEqual(text, "[secret]") }
    for kind in EvidenceKind.allCases {
      try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: kind, source: secret, sourceID: secret, documentKey: secret, project: secret, text: secret)])
    }
    for row in try store.evidence(in: all) {
      for text in [row.source, row.sourceID ?? "[secret]", row.documentKey, row.project, row.text] { XCTAssertEqual(text, "[secret]") }
    }
    try store.saveSettings(StorageSettings(excludedApps: [secret], pausedUntil: 300, screenRetentionDays: 2, promptRetentionDays: 3, general: ["invented-setting": secret]))
    let settings = try store.settings()
    XCTAssertEqual(settings.excludedApps, ["[secret]"]); XCTAssertEqual(settings.general["invented-setting"], "[secret]")
    XCTAssertEqual(settings.pausedUntil, 300); XCTAssertEqual(settings.screenRetentionDays, 2); XCTAssertEqual(settings.promptRetentionDays, 3)
    try store.saveLogPosition(LogPosition(path: secret, device: 1, inode: 2, offset: 8, state: secret, seenAt: 70))
    let position = try XCTUnwrap(store.logPosition(path: secret))
    // The returned path is caller context; the persisted cursor key is one-way.
    XCTAssertEqual(position.path, secret)
    let pathKey = AgentLogEventParser.pathIdentity(secret)
    try store.connection.namedRows("SELECT path FROM log_positions") {
      XCTAssertEqual(try $0.text("path"), pathKey)
      XCTAssertFalse(try $0.text("path").contains(secret))
    }
    XCTAssertEqual(position.state, "[secret]"); XCTAssertEqual(position.offset, 8)
    try store.appendModelCall(ModelCall(ts: 130, range: TimeRange(60, 120), model: secret, inputTokens: 10, cachedTokens: 2, outputTokens: 5, succeeded: true))
    let call = try XCTUnwrap(store.modelCalls(in: all).first)
    XCTAssertEqual(call.model, "[secret]"); XCTAssertEqual(call.inputTokens, 10); XCTAssertTrue(call.succeeded)
  }

  func testLineKeysReopenAndExactHour() throws {
    do {
      let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
      try store.appendFixtureEvidence([
        EvidenceText(ts: 1, kind: .screen, source: "invented", text: "old line"),
        EvidenceText(ts: 2, kind: .screen, source: "invented", text: "Build 123: ready!\n한글 42 줄.\n123"),
        EvidenceText(ts: 3601, kind: .screen, source: "invented", text: "Newest line"),
        EvidenceText(ts: 3602, kind: .screen, source: "invented", text: "future line"),
        EvidenceText(ts: 100, kind: .prompt, source: "invented", text: "prompt line"),
      ])
    }
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertEqual(Set(try store.recentScreenLineKeys(at: 3601).keys), Set(["Buildready", "한글줄", "Newestline", ""]))
    XCTAssertEqual(ScreenLineKey.fromMaskedLine("Build 999, ready?"), "Buildready")
  }

  func testMinuteOwnershipAndEarlierIntervals() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let first = NamedInterval(range: TimeRange(60, 180), name: "Invented work", kind: .work)
    try store.appendIntervals([first])
    XCTAssertThrowsError(try store.appendIntervals([NamedInterval(range: TimeRange(120, 240), kind: .personal)]))
    XCTAssertThrowsError(try store.appendIntervals([NamedInterval(range: TimeRange(181, 240), kind: .personal)]))
    XCTAssertThrowsError(try store.connection.run("UPDATE intervals SET name='changed'"))
    XCTAssertThrowsError(try store.connection.run("""
      INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state)
      VALUES(300,360,'','',NULL,'','pending')
      """))
    try store.appendIntervals([NamedInterval(range: TimeRange(180, 240), state: .private)])
    let rows = try store.intervals(in: all)
    XCTAssertEqual(rows.first, first); XCTAssertEqual(rows.map(\.state), [.named, .private])
    XCTAssertNil(rows[1].kind)
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 10), TimeSample(ts: 10)]),
      AppendResult(stored: 1, refused: 1))
    XCTAssertEqual(try store.samples(in: all).map(\.ts), [10])
  }

  func testDeletionPreviewFreshnessAllLayersAndSettings() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let settings = StorageSettings(excludedApps: ["invented.private"], pausedUntil: 999)
    try store.saveSettings(settings)
    try store.appendSamples([TimeSample(ts: 61), TimeSample(ts: 121)])
    try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: .prompt, source: "invented", sourceID: "row-one", text: "invented prompt"), EvidenceText(ts: 121, kind: .screen, source: "invented", text: "kept")])
    try store.appendIntervals([NamedInterval(range: TimeRange(0, 120), kind: .personal), NamedInterval(range: TimeRange(120, 180), kind: .work)])
    try store.appendModelCall(ModelCall(ts: 500, range: TimeRange(0, 120), model: "invented", succeeded: false))
    let range = TimeRange(60, 120), preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.intervalExtent, TimeRange(0, 120))
    XCTAssertEqual(preview.counts, ["samples": 1, "sample_observations": 1, "evidence": 1, "intervals": 1, "ax_probe_attempts": 0, "ax_probe_review": 0, "input_batches": 0, "collection_legacy_times": 0, "staged_collection": 0, "screen_metadata": 0, "sample_metadata": 0, "collection_metadata": 0, "agent_log_events": 0])
    XCTAssertEqual(try store.samples(in: all).count, 2)
    try store.appendFixtureEvidence([EvidenceText(ts: 62, kind: .screen, source: "invented", text: "changed snapshot")])
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.samples(in: all).count, 2)
    let fresh = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: fresh.confirmation)
    XCTAssertEqual(try store.samples(in: all).map(\.ts), [121]); XCTAssertEqual(try store.evidence(in: all).map(\.ts), [121])
    XCTAssertEqual(try store.intervals(in: all).map(\.range), [TimeRange(120, 180)])
    XCTAssertEqual(try store.modelCalls(in: all).count, 1); XCTAssertEqual(try store.settings(), settings)
    try store.appendSamples([TimeSample(ts: 70)])
    try store.appendFixtureEvidence([EvidenceText(ts: 200, kind: .prompt, source: "invented", sourceID: "row-one", text: "moved deleted prompt")])
    try store.appendIntervals([NamedInterval(range: TimeRange(60, 120), kind: .work)])
    XCTAssertEqual(try store.samples(in: all).count, 1); XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertThrowsError(try store.previewDeletion(in: TimeRange(0, 86401)))
    XCTAssertNoThrow(try store.previewDeletion(in: TimeRange(0, 86401), allowOver24Hours: true))
  }

  func testConfirmationCannotMoveToAnotherFileOrReplacement() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)), other = try ActivityStorage(url: folder.appendingPathComponent("other.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    for s in [store, other] { try s.appendSamples([TimeSample(ts: 61)]) }
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertThrowsError(try other.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("moved.sqlite"))
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
  }

  func testRetentionPerKindKeepsSkeletonIntervalsAndSettings() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let settings = StorageSettings(screenRetentionDays: 1, promptRetentionDays: 2)
    try store.saveSettings(settings)
    try store.appendSamples([TimeSample(ts: 1)])
    try store.appendIntervals([NamedInterval(range: TimeRange(0, 60), state: .private)])
    for (time, kind) in [(86400, EvidenceKind.screen), (86400, .prompt), (172800, .screen), (1, .prompt)] {
      try store.appendFixtureEvidence([EvidenceText(ts: time, kind: kind, source: "invented", text: "invented")])
    }
    XCTAssertEqual(try store.cleanRetention(at: 259200), 2)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [86400, 172800])
    XCTAssertEqual(try store.settings(), settings); XCTAssertEqual(try store.samples(in: all).count, 1)
    XCTAssertEqual(try store.intervals(in: all).count, 1)
  }

  func testOldSettingsImportOnceDefaultsAndUntouchedFiles() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertEqual(try store.settings(), StorageSettings())
    let privacy = folder.appendingPathComponent("invented-privacy.json"), general = folder.appendingPathComponent("invented-settings.json")
    let p = Data(#"{"apps":["invented.app"],"pausedUntil":123,"retentionDays":90,"autoContextProjects":["removed"]}"#.utf8)
    let g = Data(#"{"outputLanguage":"ko","dayStartHour":6}"#.utf8)
    try p.write(to: privacy); try g.write(to: general)
    XCTAssertTrue(try store.importOldSettings(privacyFile: privacy, generalFile: general))
    XCTAssertEqual(try store.settings(), StorageSettings(excludedApps: ["invented.app"], pausedUntil: 123, screenRetentionDays: 90, promptRetentionDays: 90, general: ["outputLanguage": "ko", "dayStartHour": "6"]))
    XCTAssertEqual(try Data(contentsOf: privacy), p); XCTAssertEqual(try Data(contentsOf: general), g)
    try Data("unreadable invented JSON".utf8).write(to: privacy)
    XCTAssertFalse(try store.importOldSettings(privacyFile: privacy, generalFile: general))
    let fresh = try ActivityStorage(url: folder.appendingPathComponent("fresh.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let bytes = try Data(contentsOf: privacy)
    try fresh.importOldSettings(privacyFile: privacy, generalFile: folder.appendingPathComponent("missing.json"))
    XCTAssertEqual(try fresh.settings(), StorageSettings()); XCTAssertEqual(try Data(contentsOf: privacy), bytes)
    let unreadable = folder.appendingPathComponent("unreadable-file")
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    let another = try ActivityStorage(url: folder.appendingPathComponent("another.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try another.importOldSettings(privacyFile: unreadable, generalFile: unreadable)
    XCTAssertEqual(try another.settings(), StorageSettings()); XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
  }

  func testTwoConnectionsWALAndRecorderLease() throws {
    let writer = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), role: .recorder, databaseScope: .directory(folder)), reader = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertThrowsError(try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), role: .recorder, databaseScope: .directory(folder)))
    try writer.appendSamples([TimeSample(ts: 1)])
    try writer.connection.transaction {
      try writer.insertSample(TimeSample(ts: 2))
      XCTAssertEqual(try reader.samples(in: all).map(\.ts), [1])
    }
    XCTAssertEqual(try reader.samples(in: all).map(\.ts), [1, 2])
    try reader.saveSettings(StorageSettings(pausedUntil: 500))
    XCTAssertEqual(try writer.settings().pausedUntil, 500)
    var journal = ""
    try writer.connection.rows("PRAGMA journal_mode") { journal = SQLiteConnection.text($0, 0) }
    XCTAssertEqual(journal, "wal")
  }

  func testNewerSchemaRefusedUnchanged() throws {
    do {
      let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
      try store.connection.run("PRAGMA user_version=\(SQLiteConnection.schemaVersion + 1)")
      try store.connection.run("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    let before = try Data(contentsOf: url)
    XCTAssertThrowsError(try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)))
    XCTAssertEqual(try Data(contentsOf: url), before)
  }
  func testLogEvidenceAndPositionCommitTogether() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let evidence = EvidenceText(ts: 61, kind: .prompt, source: "invented-tool", text: "invented prompt")
    XCTAssertThrowsError(try store.appendLogBatch([evidence], position: LogPosition(path: "invented-log", device: 1, inode: 1, offset: -1, seenAt: 61)))
    XCTAssertEqual(try store.evidence(in: all), [])
    XCTAssertNil(try store.logPosition(path: "invented-log"))
    try store.appendLogBatch([evidence], position: LogPosition(path: "invented-log", device: 1, inode: 1, offset: 42, seenAt: 61))
    XCTAssertEqual(try store.evidence(in: all), [evidence])
    XCTAssertEqual(try store.logPosition(path: "invented-log")?.offset, 42)
  }
  func testTextWithNullRoundTrips() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let row = EvidenceText(ts: 1, kind: .screen, source: "invented", text: "Invented\0suffix")
    try store.appendFixtureEvidence([row])
    XCTAssertEqual(try store.evidence(in: all), [row])
  }

  func testOldFractionalRetentionKeepsOtherSettings() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder)), privacy = folder.appendingPathComponent("invented-fractional.json")
    let bytes = Data(#"{"apps":["invented.private"],"retentionDays":90.5}"#.utf8)
    try bytes.write(to: privacy)
    try store.importOldSettings(privacyFile: privacy, generalFile: folder.appendingPathComponent("missing.json"))
    XCTAssertEqual(try store.settings().excludedApps, ["invented.private"])
    XCTAssertEqual(try store.settings().screenRetentionDays, 90)
    XCTAssertEqual(try Data(contentsOf: privacy), bytes)
  }

}
