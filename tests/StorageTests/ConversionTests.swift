import Core
@testable import Storage
import Foundation
import XCTest

final class ConversionTests: XCTestCase {
  var folder: URL!
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
  let all = TimeRange(0, 1000000)

  func oldDatabase() throws -> URL {
    let url = folder.appendingPathComponent("invented-old.sqlite")
    let old = try SQLiteConnection(url: url, scope: .directory(folder))
    for sql in [
      "CREATE TABLE samples(ts INTEGER,bundle_id TEXT,app TEXT,title TEXT,doc_key TEXT,keys INTEGER,clicks INTEGER,scrolls INTEGER,moved INTEGER,synth INTEGER,watching INTEGER,hidden_reason TEXT,key_source TEXT,copies INTEGER,pastes INTEGER)",
      "CREATE TABLE evidence(id INTEGER PRIMARY KEY,ts INTEGER,bundle_id TEXT,doc_key TEXT,kind TEXT,role TEXT,text TEXT,source_id TEXT,project TEXT)",
      "CREATE TABLE activities(id INTEGER PRIMARY KEY,start_ts INTEGER,end_ts INTEGER,title TEXT,summary TEXT,category TEXT,kind TEXT)",
      "CREATE TABLE hook_events(id INTEGER)", "CREATE TABLE blocks(id INTEGER)", "CREATE TABLE segments(id INTEGER)",
      "PRAGMA user_version=11",
    ] { try old.run(sql) }
    for i in 0..<8 {
      // The legacy store did not constrain seconds; even duplicates must survive the switch.
      try old.run("INSERT INTO samples VALUES(?, 'invented.app','Invented editor', 'password=inventedSecret', 'invented-document',?,0,0,0,0,1,'','title',2,3)", [.integer(60 + i / 2), .integer(i)])
      try old.run("INSERT INTO evidence VALUES(?,?, 'invented.app','invented-document',?,'invented-tool','password=inventedSecret',?, 'Invented project')", [
        .integer(i + 1), .integer(60 + i), .text(i % 2 == 0 ? "ocr" : "prompt"), .text("row-\(i)")])
    }
    for (i, category) in ["coding", "review", "research", "planning", "communication", "personal", "leisure"].enumerated() {
      try old.run("INSERT INTO activities VALUES(?,?,?,'Invented activity','Invented description',?,'normal')", [.integer(i + 1), .integer(i * 60), .integer((i + 1) * 60), .text(category)])
    }
    return url
  }

  func testConversionKindsNoLostRowsStopAndReopenRerun() throws {
    let source = try oldDatabase(), destination = folder.appendingPathComponent("new.sqlite")
    let sourceBytes = try Data(contentsOf: source)
    do {
      let store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
      let first = try store.convertOldDatabase(at: source, batchSize: 3, maxBatches: 1)
      XCTAssertEqual(first.samples, 3); XCTAssertFalse(first.finished)
      XCTAssertEqual(try store.samples(in: all).count, 3)
    }
    let store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
    let sensitive = try XCTUnwrap(folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
    let alternate = sensitive ? source : source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent.uppercased())
    let rest = try store.convertOldDatabase(at: alternate, batchSize: 3)
    XCTAssertEqual(rest.samples, 5); XCTAssertEqual(rest.evidence, 8); XCTAssertEqual(rest.intervals, 7); XCTAssertTrue(rest.finished)
    let samples = try store.samples(in: all), evidence = try store.evidence(in: all), intervals = try store.intervals(in: all)
    XCTAssertEqual(samples.count, 8); XCTAssertEqual(samples.map(\.keys), Array(0..<8)); XCTAssertEqual(evidence.count, 8)
    XCTAssertEqual(intervals.map(\.kind), [.work, .work, .work, .work, .work, .personal, .distraction])
    XCTAssertTrue(samples.allSatisfy { $0.window == "[secret]" && $0.keepingAwake })
    XCTAssertTrue(evidence.allSatisfy { $0.text == "[secret]" })
    XCTAssertEqual(Set(evidence.compactMap(\.sourceID)).count, 8)
    let again = try store.convertOldDatabase(at: source)
    XCTAssertTrue(again.finished); XCTAssertEqual(again.samples + again.evidence + again.intervals, 0)
    XCTAssertEqual(try store.samples(in: all), samples); XCTAssertEqual(try store.evidence(in: all), evidence)
    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE name IN ('hook_events','blocks','segments')"), 0)
  }

  func testFailedBatchRollsBackRowsAndCursorTogether() throws {
    let source = try oldDatabase(), destination = folder.appendingPathComponent("new.sqlite")
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("UPDATE evidence SET ts=? WHERE id=5", [.integer(Int.max)])
    }
    let store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
    XCTAssertThrowsError(try store.convertOldDatabase(at: source, batchSize: 3))
    XCTAssertEqual(try store.samples(in: all).count, 8)
    XCTAssertEqual(try store.evidence(in: all).count, 3)
    XCTAssertEqual(try store.connection.integer("SELECT last_row FROM conversion_progress WHERE layer='evidence'"), 3)
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      try old.run("UPDATE evidence SET ts=64 WHERE id=5")
    }
    _ = try store.convertOldDatabase(at: source, batchSize: 3)
    XCTAssertEqual(try store.evidence(in: all).count, 8)
  }

  func testRemovedEvidencePathsAndIntervalConflictAreExplicit() throws {
    let source = try oldDatabase(), destination = folder.appendingPathComponent("new.sqlite")
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      for kind in ["typed", "reply", "choice"] {
        try old.run("INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text) VALUES(500,'invented','',?,'','removed')", [.text(kind)])
      }
      try old.run("INSERT INTO activities VALUES(8,1,59,'Invented overlapping activity','', 'personal','normal')")
    }
    let store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source, batchSize: 3)
    XCTAssertEqual(result.skippedEmpty, 1)
    XCTAssertEqual(try store.samples(in: all).count, 8); XCTAssertEqual(try store.evidence(in: all).count, 8)
    XCTAssertEqual(try store.intervals(in: all).count, 7)
    XCTAssertTrue(try store.convertOldDatabase(at: source, batchSize: 3).finished)
    XCTAssertEqual(try store.samples(in: all).count, 8); XCTAssertEqual(try store.evidence(in: all).count, 8)
  }
  func testConversionKeepsDeletionGuardsReadingPositionsAndCallCosts() throws {
    let source = try oldDatabase(), destination = folder.appendingPathComponent("new.sqlite")
    do {
      let old = try SQLiteConnection(url: source, scope: .directory(folder))
      for sql in [
        "CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)",
        "INSERT INTO forgotten VALUES(600,660)",
        "CREATE TABLE forgotten_session_rows(bundle_id TEXT,source_id TEXT)",
        "INSERT INTO forgotten_session_rows VALUES('invented.app','deleted-row')",
        "CREATE TABLE log_cursors(path TEXT,device INTEGER,inode INTEGER,offset INTEGER,state TEXT,seen_ts INTEGER)",
        "INSERT INTO log_cursors VALUES('invented-log',1,2,123,'invented-state',500)",
        "CREATE TABLE llm_runs(created_at INTEGER,from_ts INTEGER,to_ts INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER,output_tokens INTEGER,ok INTEGER)",
        "INSERT INTO llm_runs VALUES(500,0,420,'invented-model',123,23,45,1)",
      ] { try old.run(sql) }
    }
    let bytes = try Data(contentsOf: source), store = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(folder))
    let result = try store.convertOldDatabase(at: source)
    XCTAssertTrue(result.finished)
    XCTAssertEqual(try store.logPosition(path: "invented-log")?.offset, 123)
    let call = try XCTUnwrap(store.modelCalls(in: all).first)
    XCTAssertEqual(call.inputTokens, 123); XCTAssertEqual(call.cachedTokens, 23); XCTAssertEqual(call.outputTokens, 45); XCTAssertTrue(call.succeeded)
    try store.appendSamples([TimeSample(ts: 601)])
    try store.appendEvidence([EvidenceText(ts: 700, kind: .prompt, source: "invented.app", sourceID: "deleted-row", text: "invented")])
    XCTAssertEqual(try store.samples(in: all).count, 8); XCTAssertEqual(try store.evidence(in: all).count, 8)
    XCTAssertEqual(try store.convertOldDatabase(at: source).samples, 0)
    XCTAssertEqual(try Data(contentsOf: source), bytes)
  }

  func testEmptyOldActivityIsCountedWithoutDiscardingRawRows() throws {
    let source = try oldDatabase(), store = try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    do { let old = try SQLiteConnection(url: source, scope: .directory(folder)); try old.run("INSERT INTO activities VALUES(8,480,480,'Invented empty activity','','personal','normal')") }
    XCTAssertTrue(try store.convertOldDatabase(at: source, batchSize: 3).finished)
    XCTAssertEqual(try store.samples(in: all).count, 8); XCTAssertEqual(try store.evidence(in: all).count, 8)
    XCTAssertEqual(try SQLiteConnection(url: source, readOnly: true, scope: .directory(folder)).integer("SELECT count(*) FROM activities"), 8)
  }

}
