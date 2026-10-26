import Core
@testable import Storage
import Foundation
import SQLite3
import XCTest

extension StorageTests {
  private func deletionSnapshot(_ store: ActivityStorage) throws -> [String: [[String?]]] {
    var tables: [String] = []
    try store.connection.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") {
      tables.append(SQLiteConnection.text($0, 0))
    }
    var snapshot: [String: [[String?]]] = [:]
    for table in tables {
      var rows: [[String?]] = []
      var columns = 0
      try store.connection.rows("PRAGMA table_info(\(table))") { _ in columns += 1 }
      let order = (1...columns).map(String.init).joined(separator: ",")
      try store.connection.rows("SELECT * FROM \(table) ORDER BY \(order)") { statement in
        rows.append((0..<sqlite3_column_count(statement)).map { SQLiteConnection.optionalText(statement, $0) })
      }
      snapshot[table] = rows
    }
    return snapshot
  }

  private func deletionFixture() throws -> ActivityStorage {
    let database = folder.appendingPathComponent(UUID().uuidString + ".sqlite")
    let store = try ActivityStorage(url: database, appDataDirectory: folder, databaseScope: .directory(folder))
    try store.appendSamples([TimeSample(ts: 61), TimeSample(ts: 181)])
    try store.saveSettings(StorageSettings(recordingEnabled: false))
    try store.appendFixtureEvidence(["one", "two"].map {
      EvidenceText(ts: 61, kind: .prompt, source: "invented", sourceID: $0, text: "kept")
    })
    try store.appendIntervals([NamedInterval(range: TimeRange(60, 120), kind: .work)])
    for index in 1...6 {
      try store.appendModelCall(ModelCall(ts: 90 + index, range: TimeRange(0, 360), model: "invented",
        inputTokens: index * 10, cachedTokens: index, outputTokens: index * 2, succeeded: index % 2 == 0,
        tableFacts: SummaryCallFacts(through: 360, sentRanges: [TimeRange(0, 360)],
          endsAtRest: true, activeMinutes: [0, 60, 180])))
    }
    try store.connection.run("UPDATE model_calls SET table_facts=? WHERE id IN (3,4)", [.key("{unreadable")])
    try store.connection.run("UPDATE model_calls SET table_facts='' WHERE id=5")
    try store.connection.run("UPDATE model_calls SET table_facts=NULL WHERE id=6")
    try store.saveLogPosition(LogPosition(path: "invented-log", device: 1, inode: 1, offset: 99, seenAt: 61))
    try store.connection.run("INSERT INTO conversion_progress VALUES('invented','samples',7)")
    try store.connection.run("INSERT INTO forgotten_ranges VALUES(10,20)")
    try store.connection.run("INSERT INTO forgotten_sources VALUES('invented','older')")
    return store
  }

  // Ideal: each refused write rolls back earlier erasures, billing and both marker tables.
  func testDeletionFaultsRollBackEveryTable() throws {
    let writes = [
      ("samples", "DELETE", ""), ("evidence", "DELETE", ""), ("intervals", "DELETE", ""),
      ("model_calls", "UPDATE", "WHEN OLD.id=2"), ("model_calls", "UPDATE", "WHEN OLD.id=4"),
      ("forgotten_ranges", "INSERT", ""), ("forgotten_sources", "INSERT", "WHEN NEW.source_id='two'"),
    ]
    for (table, operation, condition) in writes {
      for failure in ["ABORT,'invented failure'", "IGNORE"] {
        let store = try deletionFixture()
        try store.connection.run("""
          CREATE TRIGGER fail_deletion BEFORE \(operation) ON \(table) \(condition)
          BEGIN SELECT RAISE(\(failure)); END
          """)
        let before = try deletionSnapshot(store)
        let preview = try store.previewDeletion(in: TimeRange(60, 120))
        let context = "\(table): \(condition): \(failure)"
        XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation), context)
        XCTAssertEqual(try deletionSnapshot(store), before, context)
      }
    }
  }

  // Ideal: a later trigger cannot restore erased data, change billing, or remove required markers.
  func testDeletionChecksAllResultsAfterLastWrite() throws {
    let changes = [
      "INSERT INTO samples SELECT * FROM restore_samples",
      "INSERT INTO evidence SELECT * FROM restore_evidence",
      "INSERT INTO intervals SELECT * FROM restore_intervals",
      "UPDATE model_calls SET table_facts=(SELECT table_facts FROM restore_calls WHERE id=1) WHERE id=1",
      "UPDATE model_calls SET table_facts='{unreadable' WHERE id=3",
      "UPDATE model_calls SET input_tokens=input_tokens+1 WHERE id=6",
      "UPDATE model_calls SET start_ts=start_ts-60 WHERE id=6",
      "DELETE FROM model_calls WHERE id=6",
      "DELETE FROM forgotten_ranges WHERE start_ts=60 AND end_ts=120",
      "DELETE FROM forgotten_sources WHERE source_id='two'",
    ]
    for change in changes {
      let store = try deletionFixture()
      for (table, selection) in [("samples", "ts>=60 AND ts<120"), ("evidence", "ts>=60 AND ts<120"),
        ("intervals", "end_ts>60 AND start_ts<120")] {
        try store.connection.run("CREATE TABLE restore_\(table) AS SELECT * FROM \(table) WHERE \(selection)")
      }
      try store.connection.run("CREATE TABLE restore_calls AS SELECT * FROM model_calls")
      try store.connection.run("""
        CREATE TRIGGER undo_deletion AFTER INSERT ON forgotten_ranges
        BEGIN \(change); END
        """)
      let before = try deletionSnapshot(store)
      let preview = try store.previewDeletion(in: TimeRange(60, 120))
      XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation), change)
      XCTAssertEqual(try deletionSnapshot(store), before, change)
    }
  }

  // Ideal: normal deletion keeps every billing field and outer range, and replay stays refused.
  func testDeletionPreservesBillingAndErasesReadableAndUnreadableFacts() throws {
    let store = try deletionFixture()
    let calls = try store.modelCalls(in: all)
    let before = try deletionSnapshot(store)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let after = try deletionSnapshot(store)
    for table in before.keys where !["samples", "sample_observations", "evidence", "screen_payloads", "intervals", "model_calls", "forgotten_ranges", "forgotten_sources"].contains(table) {
      XCTAssertEqual(after[table], before[table], table)
    }
    let saved = try store.modelCalls(in: all)
    XCTAssertEqual(saved.map { call -> ModelCall in var billing = call; billing.tableFacts = nil; return billing },
      calls.map { call -> ModelCall in var billing = call; billing.tableFacts = nil; return billing })
    for call in saved.prefix(2) {
      XCTAssertEqual(call.tableFacts?.sentRanges, [TimeRange(0, 60), TimeRange(120, 360)])
      XCTAssertEqual(call.tableFacts?.activeMinutes, [0, 180])
      XCTAssertEqual(call.tableFacts?.restMinutes, [240, 300])
    }
    try store.connection.namedRows("SELECT table_facts FROM model_calls WHERE id>=3") {
      XCTAssertNil(try $0.optionalText("table_facts"))
    }
    XCTAssertEqual(try store.samples(in: all).map(\.ts), [181])
    XCTAssertEqual(try store.evidence(in: all), [])
    XCTAssertEqual(try store.intervals(in: all), [])
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 61)]), AppendResult(refused: 1))
    XCTAssertEqual(try store.appendLogBatch([
      EvidenceText(ts: 181, kind: .prompt, source: "invented", sourceID: "two", text: "replayed")],
      position: LogPosition(path: "invented-log", device: 1, inode: 1, offset: 100, seenAt: 181)), AppendResult(refused: 1))
  }

  // Ideal: outer billing ranges cannot hide inner facts; unrelated readable facts stay byte-identical.
  func testDeletionErasesFactsIndependentlyOfOuterBillingRange() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    for index in 1...3 {
      try store.appendModelCall(ModelCall(ts: 900 + index, range: TimeRange(600, 900), model: "invented",
        inputTokens: index, succeeded: true,
        tableFacts: SummaryCallFacts(through: 900,
          sentRanges: [index == 1 ? TimeRange(0, 360) : TimeRange(600, 900)], endsAtRest: false,
          activeMinutes: index == 1 ? [60] : [600])))
    }
    try store.connection.run("UPDATE model_calls SET table_facts='{unreadable' WHERE id=3")
    let before = try deletionSnapshot(store)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let calls = try store.modelCalls(in: all)
    XCTAssertEqual(calls.map(\.range), Array(repeating: TimeRange(600, 900), count: 3))
    XCTAssertEqual(calls.map(\.inputTokens), [1, 2, 3])
    XCTAssertEqual(calls[0].tableFacts?.sentRanges, [TimeRange(0, 60), TimeRange(120, 360)])
    XCTAssertEqual(calls[0].tableFacts?.activeMinutes, [])
    XCTAssertNil(calls[2].tableFacts)
    XCTAssertEqual(try deletionSnapshot(store)["model_calls"]?[1], before["model_calls"]?[1])
    try store.connection.namedRows("SELECT table_facts FROM model_calls WHERE id=3") {
      XCTAssertNil(try $0.optionalText("table_facts"))
    }
  }

  // Ideal: an existing source marker suffices, and both marker kinds prevent replay.
  func testDeletionAcceptsExistingSourceMarkerAndRefusesReplay() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let prompt = EvidenceText(ts: 61, kind: .prompt, source: "invented", sourceID: "one", text: "deleted")
    try store.appendSamples([TimeSample(ts: 61)])
    try store.appendFixtureEvidence([prompt])
    try store.connection.run("INSERT INTO forgotten_sources VALUES('invented','one')")
    try store.connection.run("""
      CREATE TRIGGER ignore_existing BEFORE INSERT ON forgotten_sources
      BEGIN SELECT RAISE(IGNORE); END
      """)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    let result = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(result.preview.counts["samples"], 1)
    XCTAssertEqual(result.preview.counts["evidence"], 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_ranges"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 1)
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 61)]), AppendResult(refused: 1))
    let replay = EvidenceText(ts: 181, kind: .prompt, source: "invented", sourceID: "one", text: "replayed")
    let position = LogPosition(path: "invented-log", device: 1, inode: 1, offset: 99, seenAt: 181)
    XCTAssertEqual(try store.appendLogBatch([prompt, replay], position: position), AppendResult(refused: 2))
    XCTAssertEqual(try store.samples(in: all), [])
    XCTAssertEqual(try store.evidence(in: all), [])
  }

  func testDeletionChecksSourceMarkersAfterRangeMarkerWrite() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try store.appendFixtureEvidence([
      EvidenceText(ts: 61, kind: .prompt, source: "invented", sourceID: "one", text: "kept")])
    try store.connection.run("""
      CREATE TRIGGER remove_source AFTER INSERT ON forgotten_ranges
      BEGIN DELETE FROM forgotten_sources; END
      """)
    let before = try deletionSnapshot(store)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try deletionSnapshot(store), before)
  }
}
