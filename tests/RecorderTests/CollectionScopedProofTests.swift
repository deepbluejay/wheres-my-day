import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionScopedProofTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try reopen()
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  func reopen() throws {
    store = nil
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func append(_ samples: [TimeSample], route: Int) throws -> AppendResult {
    try route == 0 ? store.appendAccountingSamples(samples) : store.appendSamples(samples)
  }
  func testCanonicalAcquisitionClockFaultsControlsMetadataOnlyErasureAndRestart() throws {
    for route in 0..<2 { for retention in [false, true] { for fault in [false, true] {
      let child = CollectionScopedProofTests(); try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let sample = TimeSample(ts: 101, bundleID: "invented", window: "Invented", documentKey: "invented", observedAt: 100.5)
      if fault {
        try child.store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON samples BEGIN UPDATE samples SET observed_ts=\(retention ? 103 : 99) WHERE id=NEW.id; END")
        XCTAssertThrowsError(try child.append([sample], route: route))
        XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM samples"), 0)
        try child.store.connection.run("DROP TRIGGER invented_fault")
        try child.reopen()
      }
      XCTAssertEqual(try child.append([sample], route: route).stored, 1)
      try child.reopen()
      if retention { _ = try child.store.cleanRetention(at: 30 * 86400 + 101) }
      else {
        let preview = try child.store.previewDeletion(in: TimeRange(100,101))
        XCTAssertEqual(preview.counts["sample_metadata"], 1)
        try child.store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      }
      try child.reopen()
      let retained = try XCTUnwrap(child.store.samples(in: TimeRange(101,102)).first)
      XCTAssertEqual(retained.window, ""); XCTAssertEqual(retained.documentKey, "")
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM samples WHERE observed_ts IS NOT NULL"), 0)
    } } }
  }
  func testCanonicalEveryColumnLaterRecordIgnoredInsertAndLateAccountingRollBackRetry() throws {
    let assignments = ["id=id+900", "ts=999", "bundle_id='other'", "app='other'", "window='other'", "document_key='other'", "keys=2", "clicks=2", "scrolls=2", "moved=1", "synthetic=2", "keeping_awake=1", "excluded=1", "observed_ts=99"]
    for route in 0..<2 { for assignment in assignments + ["ignored", "later", "accounting"] {
      let child = CollectionScopedProofTests(); try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let first = TimeSample(ts: 101, bundleID: "invented", window: "Invented", documentKey: "invented", observedAt: 100.5)
      let second = TimeSample(ts: 102, bundleID: "invented", observedAt: 102.5)
      let trigger: String
      switch assignment {
      case "ignored": trigger = "BEFORE INSERT ON samples BEGIN SELECT RAISE(IGNORE); END"
      case "later": trigger = "AFTER INSERT ON samples WHEN NEW.ts=102 BEGIN UPDATE samples SET observed_ts=99 WHERE ts=101; END"
      case "accounting":
        // A preexisting pending total makes this public accounting-only call
        // exercise the commit boundary without adding a parallel observation.
        trigger = "AFTER INSERT ON collection_ingestion BEGIN UPDATE samples SET observed_ts=99 WHERE ts=101; END"
      default: trigger = "AFTER INSERT ON samples BEGIN UPDATE samples SET \(assignment) WHERE id=NEW.id; END"
      }
      if assignment == "accounting" && route == 0 {
        try child.store.connection.run("UPDATE collection_ingestion_pending SET bytes=258 WHERE id=1")
      }
      try child.store.connection.run("CREATE TRIGGER invented_fault " + trigger)
      XCTAssertThrowsError(try child.append([first, second], route: route), assignment)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM samples"), 0, assignment)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM sample_observations"), 0, assignment)
      try child.store.connection.run("DROP TRIGGER invented_fault"); try child.reopen()
      XCTAssertEqual(try child.append([first, second], route: route).stored, 2)
      XCTAssertEqual(try child.append([first, second], route: route).refused, 2)
    } }
  }
  func testOrdinaryAccountingFaultsKeepReadyWorkAndProvePendingState() throws {
    for boundary in 0..<3 { for fault in [false, true] {
      let child = CollectionScopedProofTests(); try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let record = CollectionRecord(observation: ActivityObservation(id: "invented-accounting", sample: TimeSample(ts: 101, bundleID: "invented", window: "Invented")), time: 101)
      try child.store.stageCollection(record)
      if fault {
        let sql: String
        switch boundary {
        case 0: sql = "AFTER INSERT ON collection_ingestion BEGIN UPDATE collection_ingestion SET bytes=0 WHERE committed_ts=NEW.committed_ts; END"
        case 1: sql = "AFTER UPDATE ON collection_ingestion_pending WHEN NEW.bytes>0 BEGIN UPDATE collection_ingestion_pending SET bytes=0 WHERE id=1; END"
        default: sql = "BEFORE INSERT ON collection_ingestion BEGIN SELECT RAISE(IGNORE); END"
        }
        try child.store.connection.run("CREATE TRIGGER invented_fault " + sql)
      }
      let pipeline = child.store.makeCollectionPipeline(); pipeline.drain()
      XCTAssertEqual(try child.store.collectionFiles().count, fault ? 1 : 0)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures > 0, fault)
      if fault {
        XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
        try child.store.connection.run("DROP TRIGGER invented_fault"); try child.reopen()
        let retry = child.store.makeCollectionPipeline(); retry.drain()
        XCTAssertEqual(retry.takeDiagnostics().persistenceFailures, 0)
      }
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM sample_observations"), 1)
      XCTAssertGreaterThan(try child.store.connection.integer("SELECT sum(bytes) FROM collection_ingestion"), 0)
      XCTAssertEqual(try child.store.connection.integer("SELECT bytes FROM collection_ingestion_pending WHERE id=1"), 0)
      XCTAssertTrue(try child.store.collectionFiles().isEmpty)
    } }
  }
  func testEveryPublicWriteTransactionInstallsAContractAndUnplannedDeletesAreObserved() throws {
    let snapshot = try XCTUnwrap(store.connection.collectionEntrySnapshot())
    XCTAssertThrowsError(try snapshot.run("CREATE TABLE invented_write(value INTEGER)"))
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/Storage/SQLiteConnection.swift"))
    XCTAssertTrue(source.contains("if write { collectionMaintenanceProof = try CollectionMaintenanceProof(self, full: collectionFullBaseline) }"))
    let storage = root.appendingPathComponent("Sources/Storage")
    let fullCallers = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil).filter {
      try String(contentsOf: $0).contains("collectionFullBaseline: true")
    }.map(\.lastPathComponent)
    XCTAssertEqual(fullCallers, ["Schema.swift"], "Routine public paths must use scoped contracts")
    // A registered statement is insufficient: even ordinary public transactions
    // must refuse unregistered writes to every relation, including accounting.
    for table in CollectionMaintenanceProof.tables {
      XCTAssertThrowsError(try store.connection.collectionWrite("DELETE FROM \(table) WHERE 0"), "Registration alone must never authorize a write")
      XCTAssertThrowsError(try store.connection.transaction { try store.connection.run("DELETE FROM \(table) WHERE 0") }, table)
    }
    try store.appendObservations([ActivityObservation(id: "invented-existing", sample: TimeSample(ts: 50, bundleID: "invented"))])
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON samples BEGIN DELETE FROM sample_observations; END")
    XCTAssertThrowsError(try store.appendAccountingSamples([TimeSample(ts: 101, bundleID: "invented")]))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 1)
    XCTAssertEqual(try snapshot.integer("SELECT count(*) FROM sample_observations"), 0, "Entry snapshot must not observe later writes")
  }
  func testInterruptedBatchesKeepTombstoneAndCanResumeWithFreshPreview() throws {
    for retention in [false, true] {
      let child = CollectionScopedProofTests(); try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let observations = (100..<400).map { ActivityObservation(id: "invented-\($0)", sample: TimeSample(ts: $0, bundleID: "invented")) }
      try child.store.appendObservations(observations)
      for time in [100,300,399] {
        _ = try child.store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented \(time)"), at: time, source: "invented", documentKey: "", project: "", probe: nil)
      }
      try child.store.stageCollection(CollectionRecord(observation: ActivityObservation(id: "invented-staged", sample: TimeSample(ts: 150, bundleID: "invented")), time: 150))
      try child.store.connection.run("CREATE TRIGGER invented_fault BEFORE DELETE ON sample_observations WHEN OLD.ts=300 BEGIN SELECT RAISE(ABORT,'invented interruption'); END")
      let range = TimeRange(100,400), preview = try child.store.previewDeletion(in: range)
      if retention { XCTAssertThrowsError(try child.store.cleanRetention(at: 30 * 86400 + 400)) }
      else { XCTAssertThrowsError(try child.store.deleteRecords(in: range, confirmation: preview.confirmation)) }
      let remaining = try child.store.connection.integer("SELECT count(*) FROM sample_observations")
      XCTAssertGreaterThan(remaining, 0); XCTAssertLessThan(remaining, 300)
      XCTAssertEqual(try child.store.collectionFiles().count, 1)
      try child.store.connection.run("DROP TRIGGER invented_fault"); try child.reopen()
      let result = try child.store.appendObservations([observations[0]])
      XCTAssertEqual(result.stored, 0)
      if retention {
        var settings = try child.store.settings(); settings.screenRetentionDays = 31
        try child.store.saveSettings(settings, at: 400)
      }
      let fresh = try child.store.previewDeletion(in: range)
      XCTAssertNotEqual(fresh.confirmation, preview.confirmation)
      if retention { _ = try child.store.cleanRetention(at: 30 * 86400 + 400) }
      else { try child.store.deleteRecords(in: range, confirmation: fresh.confirmation) }
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
      XCTAssertTrue(try child.store.collectionFiles().isEmpty)
      XCTAssertTrue(try child.store.evidence(in: range).isEmpty)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_blobs"), 0)
    }
  }
  func testEveryDeletionBatchVerifiesTombstoneAfterAccounting() throws {
    let values = (100..<300).map { ActivityObservation(id: "invented-\($0)", sample: TimeSample(ts: $0, bundleID: "invented")) }
    try store.appendObservations(values)
    try store.connection.run("CREATE TRIGGER invented_fault AFTER DELETE ON sample_observations BEGIN DELETE FROM forgotten_ranges; END")
    let preview = try store.previewDeletion(in: TimeRange(100,300))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 200)
    try store.connection.run("DROP TRIGGER invented_fault")
    try reopen()
    let fresh = try store.previewDeletion(in: preview.range)
    try store.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
    XCTAssertEqual(try store.appendObservations([values[0]]).stored, 0)
  }

  func testMetadataAdmissionAndPreparedWritesCannotStraddleACheckpoint() throws {
    var commits = 0
    store.connection.collectionCommitClock = { commits += 1; return 200_000 }
    try store.connection.transaction(collectionMaintenance: true) {
      try store.connection.enableCollectionMaintenanceBatches()
      store.connection.collectionBatchChanges = 64
      try store.connection.withCollectionMaintenanceUnit {
        XCTAssertEqual(commits, 1, "Checkpoint before computing admission")
        store.connection.collectionBatchChanges = 64
        _ = try store.connection.integer("SELECT count(*) FROM settings")
        try store.connection.collectionWrite("UPDATE collection_ingestion_pending SET bytes=0 WHERE id=1")
        XCTAssertEqual(commits, 1, "Prepared writes must remain in the admission transaction")
      }
      try store.connection.withCollectionMaintenanceUnit {
        XCTAssertEqual(commits, 2, "Next component gets a fresh transaction snapshot")
      }
    }
    XCTAssertEqual(commits, 3)
  }

  func testEveryDeletionBatchPreservesUnrelatedBillingBeforeCommit() throws {
    let values = (100..<300).map { ActivityObservation(id: "invented-\($0)", sample: TimeSample(ts: $0, bundleID: "invented")) }
    try store.appendObservations(values)
    try store.appendModelCall(ModelCall(ts: 500, range: TimeRange(0,600), model: "invented", inputTokens: 10, cachedTokens: 0, outputTokens: 0, succeeded: true))
    try store.connection.run("CREATE TRIGGER invented_fault AFTER DELETE ON sample_observations WHEN OLD.ts=100 BEGIN UPDATE model_calls SET input_tokens=input_tokens+1; END")
    let preview = try store.previewDeletion(in: TimeRange(100,300))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 200)
    XCTAssertEqual(try store.connection.integer("SELECT input_tokens FROM model_calls WHERE id=1"), 10)
  }

  func testIgnoredProgressMarkerCannotBorrowAnUnrelatedIdentity() throws {
    try store.appendObservations([ActivityObservation(id: "invented", sample: TimeSample(ts: 100, bundleID: "invented"))])
    try store.connection.run("INSERT INTO forgotten_ranges VALUES(1,2)")
    try store.connection.run("INSERT INTO forgotten_ranges VALUES(100,101)")
    try store.connection.run("CREATE TABLE invented_counter(id INTEGER PRIMARY KEY)")
    try store.connection.run("INSERT INTO invented_counter VALUES(1)")
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON forgotten_ranges BEGIN SELECT RAISE(IGNORE); END")
    let preview = try store.previewDeletion(in: TimeRange(100,101))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_ranges"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_ranges WHERE start_ts=1 AND end_ts=2"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 1)
  }

}
