import Core
@testable import Storage
import Foundation
import SQLite3
import XCTest

extension ConversionTests {
  func testActivityRuleHandlesOverlapTiesAwayUnknownPrivateAndFallback() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("ALTER TABLE activities ADD COLUMN away INTEGER DEFAULT 0")
      try old.run("DELETE FROM activities")
      let rows: [(Int, Int, Int, String, String, Int)] = [
        (1, 671, 731, "leisure", "normal", 0), (90, 610, 670, "custom", "normal", 0),
        (8, 541, 601, "unclassified", "normal", 0), (70, 480, 540, "personal", "private", 0),
        (6, 420, 480, "personal", "unknown", 0), (5, 360, 420, "coding", "normal", 1),
        (4, 310, 350, "coding", "normal", 0), (3, 70, 150, "coding", "normal", 0),
        (200, 61, 301, "personal", "normal", 0), (100, 61, 241, "coding", "normal", 0)]
      for (id, start, end, category, kind, away) in rows {
        try old.run("INSERT INTO activities VALUES(?,?,?,'Invented activity','',?,?,?)",
          [.integer(id), .integer(start), .integer(end), .text(category), .text(kind), .integer(away)])
      }
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let first = try store.convertOldDatabase(at: source, batchSize: 2, maxBatches: 9)
    let rest = try store.convertOldDatabase(at: source, batchSize: 2)
    XCTAssertTrue(rest.finished)
    XCTAssertEqual(first.intervals + rest.intervals, 6)
    XCTAssertEqual(first.shortened + rest.shortened, 1)
    XCTAssertEqual(first.skippedAway + rest.skippedAway, 1)
    XCTAssertEqual(first.skippedUnknown + rest.skippedUnknown, 1)
    XCTAssertEqual(first.skippedEmpty + rest.skippedEmpty, 2)
    let rows = try store.intervals(in: all)
    XCTAssertEqual(rows.map(\.range), [TimeRange(60, 240), TimeRange(240, 300), TimeRange(480, 540),
      TimeRange(540, 600), TimeRange(600, 660), TimeRange(660, 720)])
    XCTAssertEqual(rows.map(\.kind), [.work, .personal, nil, .work, .work, .distraction])
    XCTAssertEqual(rows.map(\.state), [.named, .named, .private, .named, .named, .named])
  }

  func testHiddenContentEvidenceIsNotCarried() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(500,'invented','(비공개)','ocr','','HIDDEN_INVENTED')")
      try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(501,'invented','(비공개)','prompt','','HIDDEN_INVENTED')")
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source)
    XCTAssertEqual(result.evidence, 8)
    XCTAssertEqual(try store.evidence(in: all).count, 8)
    XCTAssertFalse(try store.evidence(in: all).contains { $0.text == "HIDDEN_INVENTED" })
  }

  func testFrozenWALBackupIsImmutableAndLiveSourceIsRefused() throws {
    let original = try oldDatabase()
    let old = try SQLiteConnection(url: original, scope: .directory(folder))
    try old.run("PRAGMA journal_mode=WAL")
    try old.run("INSERT INTO samples SELECT * FROM samples WHERE rowid=1")
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertThrowsError(try store.convertOldDatabase(at: original))
    XCTAssertEqual(try store.samples(in: all), [])
    let copies = folder.appendingPathComponent("frozen")
    try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
    let copy = copies.appendingPathComponent("backup with spaces.sqlite")
    do {
      let target = try SQLiteConnection(url: copy, scope: .directory(folder))
      let backup = try XCTUnwrap(sqlite3_backup_init(target.handle, "main", old.handle, "main"))
      XCTAssertEqual(sqlite3_backup_step(backup, -1), SQLITE_DONE)
      XCTAssertEqual(sqlite3_backup_finish(backup), SQLITE_OK)
    }
    let before = try Data(contentsOf: copy)
    XCTAssertEqual(before[18], 2)
    let listing = try FileManager.default.contentsOfDirectory(atPath: copies.path)
    XCTAssertEqual(listing, [copy.lastPathComponent])
    let result = try store.convertOldDatabase(at: copy)
    XCTAssertEqual(result.samples, 9)
    XCTAssertEqual(result.evidence, 8)
    XCTAssertEqual(try Data(contentsOf: copy), before)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copies.path), listing)
  }

  func testConversionRefusesDifferentSourceAndPopulatedDestination() throws {
    let source = try oldDatabase(), destination = folder.appendingPathComponent("new.sqlite")
    let store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertFalse(try store.convertOldDatabase(at: source, batchSize: 3, maxBatches: 1).finished)
    let copy = folder.appendingPathComponent("another-source.sqlite")
    try FileManager.default.copyItem(at: source, to: copy)
    XCTAssertThrowsError(try store.convertOldDatabase(at: copy))
    XCTAssertEqual(try store.samples(in: all).count, 3)
    XCTAssertTrue(try store.convertOldDatabase(at: source).finished)
    for table in ["samples", "settings", "model_calls", "forgotten_ranges"] {
      let populated = try ActivityStorage(url: folder.appendingPathComponent("populated-\(table).sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
      switch table {
      case "samples": try populated.appendSamples([TimeSample(ts: 61)])
      case "settings": try populated.saveSettings(StorageSettings())
      case "model_calls": try populated.appendModelCall(ModelCall(ts: 61, range: TimeRange(60, 120), model: "invented", succeeded: true))
      default: try populated.connection.run("INSERT INTO forgotten_ranges VALUES(60,120)")
      }
      XCTAssertThrowsError(try populated.convertOldDatabase(at: source))
      XCTAssertEqual(try populated.connection.integer("SELECT count(*) FROM conversion_progress"), 0)
    }
  }

  func testConversionCountsRefusedRowsAndKeepsCallCosts() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      for sql in [
        "CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)", "INSERT INTO forgotten VALUES(60,120)",
        "CREATE TABLE llm_runs(created_at INTEGER,from_ts INTEGER,to_ts INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER,output_tokens INTEGER,ok INTEGER)",
        "INSERT INTO llm_runs VALUES(90,0,3600,'invented',10,2,3,0)"] { try old.run(sql) }
    }
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source)
    XCTAssertEqual(result.samples, 0)
    XCTAssertEqual(result.refusedSamples, 8)
    XCTAssertEqual(result.evidence, 0)
    XCTAssertEqual(result.refusedEvidence, 8)
    XCTAssertEqual(result.intervals, 6)
    XCTAssertEqual(result.refusedIntervals, 1)
    XCTAssertEqual(try store.modelCalls(in: all).count, 1)
  }

  func testOldWantedRecordingOffSurvivesLaterSettingsImport() throws {
    let source = try oldDatabase()
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("CREATE TABLE wanted(id INTEGER PRIMARY KEY,recording INTEGER,since_ts INTEGER)")
      try old.run("INSERT INTO wanted VALUES(1,0,123)")
    }
    let privacy = folder.appendingPathComponent("invented-privacy.json")
    try Data(#"{"pausedUntil":999}"#.utf8).write(to: privacy)
    let store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    _ = try store.convertOldDatabase(at: source)
    XCTAssertFalse(try store.settings().recordingEnabled)
    XCTAssertNil(try store.settings().pausedUntil)
    try store.importOldSettings(privacyFile: privacy, generalFile: folder.appendingPathComponent("missing.json"))
    XCTAssertFalse(try store.settings().recordingEnabled)
    XCTAssertEqual(try store.settings().pausedUntil, 999)
  }
}
