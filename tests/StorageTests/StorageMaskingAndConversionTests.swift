import Core
@testable import Storage
import Foundation
import SQLite3
import XCTest

extension StorageTests {
  func testWholeCaptureMaskedBeforeLineSelectionAndRebuild() throws {
    let block = """
      -----BEGIN PRIVATE KEY-----
      INVENTED_SECRET_BODY_ALPHA_ABCXYZ
      INVENTED_SECRET_BODY_BETA_ABCXYZ
      -----END PRIVATE KEY-----
      """
    let page = (["password=inventedFirst", "password=inventedSecond", block]
      + (0..<13).map { "Invented page line " + String(UnicodeScalar(65 + $0)!) }).joined(separator: "\n")
    for (index, capture) in [block, page].enumerated() {
      let database = folder.appendingPathComponent("capture-\(index).sqlite")
      var keys = Set<String>()
      do {
        let store = try ActivityStorage(url: database, appDataDirectory: database.deletingLastPathComponent(), databaseScope: .directory(folder))
        for i in 0..<8 {
          let result = try store.appendScreenCapture(
            text: capture, at: 60 + i * 15, source: "invented-screen", knownKeys: keys)
          XCTAssertEqual(result.append, AppendResult(stored: 1))
          XCTAssertEqual(result.addedKeys.count, index == 0 ? 1 : 14)
          keys.formUnion(result.addedKeys)
          XCTAssertEqual(Set(try store.recentScreenLineKeys(at: 60 + i * 15).keys), keys)
        }
        XCTAssertEqual(try store.evidence(in: all).count, 8)
        for file in [database.path, database.path + "-wal"] {
          let bytes = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
          for body in ["INVENTED_SECRET_BODY_ALPHA_ABCXYZ", "INVENTED_SECRET_BODY_BETA_ABCXYZ"] {
            XCTAssertNil(bytes.range(of: Data(body.utf8)))
          }
        }
      }
      let reopened = try ActivityStorage(url: database, appDataDirectory: database.deletingLastPathComponent(), databaseScope: .directory(folder))
      XCTAssertEqual(Set(try reopened.recentScreenLineKeys(at: 165).keys), keys)
      XCTAssertEqual(try reopened.recentScreenLineKeys(at: 3660), [:])
    }
  }

  func testScreenCaptureRefusalAddsNoKeys() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let result = try store.appendScreenCapture(text: "Invented line", at: 61, source: "invented", knownKeys: [])
    XCTAssertEqual(result.append, AppendResult(refused: 1))
    XCTAssertEqual(result.addedKeys, [])
    XCTAssertEqual(try store.recentScreenLineKeys(at: 61), [:])
  }

  func testRepeatedSecondRefusedWithoutLosingRestOfBatch() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: 10), TimeSample(ts: 11), TimeSample(ts: 12)]),
      AppendResult(stored: 3))
    XCTAssertEqual(try store.appendSamples([
      TimeSample(ts: 13), TimeSample(ts: 11), TimeSample(ts: 14), TimeSample(ts: 14), TimeSample(ts: 15)]),
      AppendResult(stored: 3, refused: 2))
    XCTAssertEqual(try store.samples(in: all).map(\.ts), Array(10...15))
    XCTAssertEqual(try store.observations(in: all).count, 8)
  }

  func testDeletionReportsDelayedTruncationUsesShortWaitAndRecorderOpenRetries() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), busyMilliseconds: 3000, databaseScope: .directory(folder))
    let reader = try SQLiteConnection(url: url, scope: .directory(folder))
    let marker = "INVENTED_MARKER_AAAAAAAAAAAAAAAAAAAAAAAA"
    try store.appendFixtureEvidence([EvidenceText(ts: 61, kind: .screen, source: "invented", text: marker)])
    try reader.run("BEGIN")
    XCTAssertEqual(try reader.integer("SELECT count(*) FROM evidence"), 1)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    let start = Date()
    let result = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertFalse(result.walTruncated)
    XCTAssertEqual(result.preview, preview)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    XCTAssertEqual(try store.connection.integer("PRAGMA busy_timeout"), 3000)
    XCTAssertEqual(try store.evidence(in: all), [])
    let wal = URL(fileURLWithPath: url.path + "-wal")
    XCTAssertNotNil(try Data(contentsOf: wal).range(of: Data(marker.utf8)))
    let startOpen = Date()
    do {
      _ = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), role: .recorder, busyMilliseconds: 3000, databaseScope: .directory(folder))
      XCTAssertLessThan(Date().timeIntervalSince(startOpen), 1)
    }
    try reader.run("COMMIT")
    let recorder = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), role: .recorder, databaseScope: .directory(folder))
    XCTAssertEqual(try recorder.connection.integer("PRAGMA busy_timeout"), 0)
    XCTAssertNil(try Data(contentsOf: wal).range(of: Data(marker.utf8)))
  }

  func testRetentionTruncatesWALAfterSnapshotEnds() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    let marker = "INVENTED_RETENTION_MARKER_ABCXYZ"
    try store.appendFixtureEvidence([EvidenceText(ts: 1, kind: .screen, source: "invented", text: marker)])
    let reader = try SQLiteConnection(url: url, scope: .directory(folder))
    try reader.run("BEGIN")
    XCTAssertEqual(try reader.integer("SELECT count(*) FROM evidence"), 1)
    XCTAssertEqual(try store.cleanRetention(at: 31 * 86400), 1)
    try reader.run("COMMIT")
    XCTAssertEqual(try store.cleanRetention(at: 31 * 86400), 0)
    for file in [url.path, url.path + "-wal"] {
      let bytes = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
      XCTAssertNil(bytes.range(of: Data(marker.utf8)))
    }
  }

  func testForgottenRangesReadOnlyReturnsIntersectingRanges() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    for range in [TimeRange(0, 60), TimeRange(120, 180), TimeRange(200, 240)] {
      let preview = try store.previewDeletion(in: range)
      try store.deleteRecords(in: range, confirmation: preview.confirmation)
    }
    let port: ForgottenRangeReader = store
    XCTAssertEqual(try port.forgottenRanges(in: TimeRange(60, 200)), [TimeRange(120, 180)])
    XCTAssertEqual(try port.forgottenRanges(in: TimeRange(30, 210)),
      [TimeRange(0, 60), TimeRange(120, 180), TimeRange(200, 240)])
  }

  func testMissingColumnIsAnErrorForEveryNamedGetter() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: url.deletingLastPathComponent(), databaseScope: .directory(folder))
    try store.connection.namedRows("SELECT 7 AS present,NULL AS absent_value") { row in
      XCTAssertEqual(try row.int("present"), 7)
      XCTAssertNil(try row.optionalText("absent_value"))
      XCTAssertEqual(try row.text("absent_value"), "")
      XCTAssertThrowsError(try row.int("missing"))
      XCTAssertThrowsError(try row.text("missing"))
      XCTAssertThrowsError(try row.optionalText("missing"))
    }
  }
}

extension ConversionTests {
  func testInvalidOldConstraintsAreCountedAndConversionContinues() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      for (index, column) in ["keys", "clicks", "scrolls", "synth"].enumerated() {
        try old.run("UPDATE samples SET \(column)=-1 WHERE rowid=?", [.integer(index + 2)])
      }
      for sql in [
        "CREATE TABLE log_cursors(path TEXT,device INTEGER,inode INTEGER,offset INTEGER,state TEXT,seen_ts INTEGER)",
        "INSERT INTO log_cursors VALUES('invalid-log',1,2,-1,'',60)",
        "INSERT INTO log_cursors VALUES('valid-log',1,2,42,'',60)",
        "CREATE TABLE llm_runs(created_at INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER," +
          "output_tokens INTEGER,ok INTEGER)",
        "INSERT INTO llm_runs VALUES(60,'invented',-1,0,0,1)",
        "INSERT INTO llm_runs VALUES(61,'invented',0,-1,0,1)",
        "INSERT INTO llm_runs VALUES(62,'invented',0,0,-1,1)",
        "INSERT INTO llm_runs VALUES(63,'invented',5,1,2,1)",
      ] { try old.run(sql) }
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let first = try store.convertOldDatabase(at: source, batchSize: 3, maxBatches: 2)
    let rest = try store.convertOldDatabase(at: source, batchSize: 3)
    XCTAssertTrue(rest.finished)
    XCTAssertEqual(first.refusedSamples + rest.refusedSamples, 4)
    XCTAssertEqual(first.samples + rest.samples, 4)
    XCTAssertEqual(try store.samples(in: all).map(\.keys), [0, 5, 6, 7])
    XCTAssertEqual(try store.evidence(in: all).count, 8)
    XCTAssertEqual(try store.intervals(in: all).count, 7)
    XCTAssertNil(try store.logPosition(path: "invalid-log"))
    XCTAssertEqual(try store.logPosition(path: "valid-log")?.offset, 42)
    XCTAssertEqual(first.tables["log_cursors"]?.carried, 1)
    XCTAssertEqual(first.tables["log_cursors"]?.refused, 1)
    XCTAssertEqual(rest.tables["llm_runs"]?.carried, 1)
    XCTAssertEqual(rest.tables["llm_runs"]?.refused, 3)
    XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [5])
    let old = try SQLiteConnection(url: source, readOnly: true, immutable: true, scope: .directory(folder))
    for name in Set(first.tables.keys).union(rest.tables.keys) {
      let a = first.tables[name, default: ConversionTableCounts()]
      let b = rest.tables[name, default: ConversionTableCounts()]
      XCTAssertEqual(try old.integer("SELECT count(*) FROM \(name)"),
        a.carried + a.refused + a.notCarried + b.carried + b.refused + b.notCarried, name)
    }
    XCTAssertEqual(try store.convertOldDatabase(at: source).tables, [:])
  }

  func testOldHiddenSamplesLoseWindowAndDocumentKey() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("UPDATE samples SET title='INVENTED_HIDDEN_WINDOW',hidden_reason='excluded' WHERE rowid=1")
      try old.run("UPDATE samples SET title='INVENTED_HIDDEN_WINDOW',doc_key='(비공개)' WHERE rowid=2")
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source)
    XCTAssertEqual(result.samples, 8)
    let samples = try store.samples(in: all)
    XCTAssertEqual(samples.prefix(2).map(\.excluded), [true, true])
    XCTAssertEqual(samples.prefix(2).map(\.window), ["", ""])
    XCTAssertEqual(samples.prefix(2).map(\.documentKey), ["", ""])
    XCTAssertTrue(samples.dropFirst(2).allSatisfy { !$0.excluded && !$0.documentKey.isEmpty })
  }

  func testConversionCountsEveryRowAndDroppedEvidenceByReason() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      for kind in ["typed", "reply", "choice", "reply"] {
        try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(500,'invented','',?,'','')",
          [.text(kind)])
      }
      try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(501,'invented','(비공개)','ocr','','')")
      try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(502,'invented','(비공개)','prompt','','')")
      try old.run("INSERT INTO evidence SELECT 99,ts,bundle_id,doc_key,kind,role,text,source_id,project FROM evidence WHERE id=1")
      try old.run("CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)")
      try old.run("INSERT INTO forgotten VALUES(60,61)")
      try old.run("CREATE TABLE forgotten_session_rows(bundle_id TEXT,source_id TEXT)")
      try old.run("INSERT INTO forgotten_session_rows VALUES('invented','removed')")
      try old.run("CREATE TABLE wanted(recording INTEGER)")
      try old.run("INSERT INTO wanted VALUES(0)")
      try old.run("CREATE TABLE log_cursors(path TEXT,device INTEGER,inode INTEGER,offset INTEGER,state TEXT,seen_ts INTEGER)")
      try old.run("INSERT INTO log_cursors VALUES('invented',1,2,0,'',60)")
      try old.run("CREATE TABLE llm_runs(created_at INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER," +
        "output_tokens INTEGER,ok INTEGER)")
      try old.run("INSERT INTO llm_runs VALUES(60,'invented',1,0,0,1)")
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source, batchSize: 3)
    let old = try SQLiteConnection(url: source, readOnly: true, immutable: true, scope: .directory(folder))
    for (name, counts) in result.tables {
      XCTAssertEqual(try old.integer("SELECT count(*) FROM \(name)"),
        counts.carried + counts.refused + counts.notCarried, name)
    }
    XCTAssertEqual(result.tables.count, 8)
    XCTAssertEqual(result.skippedEvidenceKinds, ["typed": 1, "reply": 2, "choice": 1])
    XCTAssertEqual(result.skippedHiddenEvidence, 2)
    XCTAssertEqual(result.tables["evidence"]?.notCarried, 6)
    XCTAssertEqual(result.tables["evidence"]?.refused, 2)
    XCTAssertEqual(result.refusedEvidence, 2)
  }

  func testFlooredActivityInsideForgottenRangeIsCountedAsRefused() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("DELETE FROM activities")
      try old.run("CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)")
      try old.run("INSERT INTO forgotten VALUES(60,90)")
      try old.run("INSERT INTO activities VALUES(1,95,1295,'Invented','','personal','normal')")
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source)
    XCTAssertEqual(result.refusedIntervals, 1)
    XCTAssertEqual(try store.intervals(in: all), [])
  }
}
