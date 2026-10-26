import Core
import CryptoKit
import Darwin
import Foundation
import Shell
import XCTest
@testable import Storage

final class CollectionRecoveryTests: XCTestCase {
  var folder: URL!
  var store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try open(folder)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func open(_ folder: URL) throws -> ActivityStorage {
    let db = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try db.saveSettings(StorageSettings(excludedApps: [])); return db
  }
  func observation(_ time: Int, id: String = UUID().uuidString, events: [InputObservation] = []) -> ActivityObservation {
    ActivityObservation(id: id, sample: TimeSample(ts: time, bundleID: "invented", window: "Invented window", inputEvents: events))
  }
  let all = TimeRange(0, 100_000)

  func testCrashPublicationFixture() throws {
    guard let root = ProcessInfo.processInfo.environment["AP_COLLECTION_CRASH_ROOT"],
      let point = ProcessInfo.processInfo.environment["AP_COLLECTION_CRASH_POINT"] else { return }
    let db = try open(URL(fileURLWithPath: root))
    db.collectionPublicationFault = { if $0 == point { _exit(73) } }
    try db.stageCollection(CollectionRecord(observation: observation(1), time: 1))
    XCTFail("Crash point was not reached")
  }
  func testInterruptedPublicationAndDamagedReadyCannotStarvePersistenceOrPrivacy() throws {
    for point in ["before-write", "during-write", "before-rename", "after-rename", "after-sync"] {
      let root = folder.appendingPathComponent(point)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let db = try open(root), child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["-XCTest", "RecorderTests.CollectionRecoveryTests/testCrashPublicationFixture", Bundle(for: Self.self).bundleURL.path]
      var environment = ProcessInfo.processInfo.environment
      environment["ACTIVITYPROBE_TEST_ROOT"] = root.path
      environment["AP_COLLECTION_CRASH_ROOT"] = root.path; environment["AP_COLLECTION_CRASH_POINT"] = point
      child.environment = environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 73)
      let published = point == "after-rename" || point == "after-sync"
      XCTAssertEqual(try db.collectionFiles().count, published ? 1 : 0)
      try Data("{".utf8).write(to: db.collectionDirectory.appendingPathComponent("00000000000000000000-damaged.json"))
      try db.stageCollection(CollectionRecord(observation: observation(100), time: 100))
      let interruptedPreview = try db.previewDeletion(in: TimeRange(100,101))
      XCTAssertEqual(interruptedPreview.counts["staged_collection"], published ? 2 : 3)
      try db.recoverCollectionSpool()
      let preview = try db.previewDeletion(in: TimeRange(100, 101))
      XCTAssertEqual(preview.counts["staged_collection"], 2)
      XCTAssertTrue(FileManager.default.fileExists(atPath: db.collectionDirectory.appendingPathComponent("00000000000000000000-damaged.json").path))
      let hidden = try FileManager.default.contentsOfDirectory(atPath: db.collectionDirectory.path)
      XCTAssertFalse(hidden.contains { $0.hasPrefix(".tmp-") })
      let pipeline = CollectionPipeline(writer: db); pipeline.drain()
      XCTAssertEqual(try db.observations(in: TimeRange(100,101)).count, 1)
      XCTAssertEqual(try db.collectionFiles().count, 0)
      XCTAssertTrue(try db.collectionStatus().contains("collection_quarantined_rows=1"))
      let fresh = try db.previewDeletion(in: TimeRange(100, 101))
      try db.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
      XCTAssertTrue(try db.collectionStatus().contains("collection_quarantined_rows=0"))
      XCTAssertEqual(try db.observations(in: all).count, published ? 1 : 0)
    }
  }
  func testQuarantineFreshnessAndRetentionTreatUnknownTimeAsOverlappingEveryRange() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    let damaged = store.collectionDirectory.appendingPathComponent("damaged.json")
    try Data("{".utf8).write(to: damaged)
    let a = try store.previewDeletion(in: TimeRange(100,101))
    _ = try store.readReadyCollection(damaged)
    let quarantined = store.collectionQuarantine.appendingPathComponent("damaged.json")
    try Data("{x".utf8).write(to: quarantined)
    XCTAssertThrowsError(try store.deleteRecords(in: a.range, confirmation: a.confirmation))
    _ = try store.cleanRetention(at: 30 * 86400 + 101)
    XCTAssertFalse(FileManager.default.fileExists(atPath: quarantined.path))
  }
  func testReadOnlyStagingDirectoryRetainsAcceptedMaskedWorkAndRetriesInOrder() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
    let pipeline = CollectionPipeline(writer: store)
    var first = observation(100); first.sample.window = "password=inventedSecret"
    XCTAssertTrue(pipeline.offer(first)); pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 0)
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
    XCTAssertTrue(pipeline.offer(observation(101)))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.collectionDirectory.path)
    pipeline.retry(); pipeline.drain()
    let rows = try store.observations(in: all)
    XCTAssertEqual(rows.map(\.sample.ts), [100, 101]); XCTAssertEqual(rows.first?.sample.window, "[secret]")
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }
  func testEveryPublicationFailureRetainsTheOnlyCopyUntilRetryIncludingPolicyReads() throws {
    for point in ["policy-read", "before-write", "during-write", "file-sync", "before-rename", "after-rename", "directory-sync", "after-sync"] {
      let time = 100 + ["policy-read", "before-write", "during-write", "file-sync", "before-rename", "after-rename", "directory-sync", "after-sync"].firstIndex(of: point)!
      store.collectionPublicationFault = { if $0 == point { throw StorageError("Invented publication failure") } }
      let pipeline = CollectionPipeline(writer: store)
      XCTAssertTrue(pipeline.offer(observation(time, events: [InputObservation(kind: .move, timestamp: Double(time))])))
      pipeline.drain()
      let diagnostics = pipeline.takeDiagnostics()
      XCTAssertGreaterThan(diagnostics.stagingFailures, 0); XCTAssertGreaterThan(diagnostics.retainedBytes, 0)
      XCTAssertLessThanOrEqual(diagnostics.retainedBytes, CollectionPipeline.queueBytes)
      store.collectionPublicationFault = nil
      pipeline.retry(); pipeline.drain()
      XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
      XCTAssertEqual(try store.observations(in: TimeRange(time,time+1)).count, 1)
      XCTAssertEqual(try store.inputEvents(in: TimeRange(time,time+1)).count, 1)
      XCTAssertEqual(try store.collectionFiles().count, 0)
    }
  }
  func testUnpublishedWorkRechecksForgetBeforePublication() throws {
    store.collectionPublicationFault = { if $0 == "policy-read" { throw StorageError("Invented read failure") } }
    let pipeline = CollectionPipeline(writer: store)
    XCTAssertTrue(pipeline.offer(observation(100))); pipeline.drain()
    let preview = try store.previewDeletion(in: TimeRange(100,101))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    store.collectionPublicationFault = nil; pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 0); XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }
  func testLargeBacklogPreviewForgetAndRetentionReadOnlyOnePayloadAtATime() throws {
    let text = String(repeating: "a", count: 1024 * 1024)
    for i in 0..<64 {
      var value = observation(100 + i); value.sample.window = text
      try store.stageCollection(CollectionRecord(observation: value, time: 100+i))
    }
    let preview = try store.previewDeletion(in: TimeRange(100,132))
    XCTAssertEqual(preview.counts["staged_collection"], 32)
    XCTAssertLessThan(store.collectionPeakReadBytes, 2 * 1024 * 1024)
    XCTAssertEqual(preview.confirmation, try store.previewDeletion(in: preview.range).confirmation)
    let file = try XCTUnwrap(store.collectionFiles(limit: 1).first)
    var value = try XCTUnwrap(store.readReadyCollection(file)); value.observation?.sample.window += "b"
    try JSONEncoder().encode(value).write(to: file)
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    let fresh = try store.previewDeletion(in: preview.range)
    try store.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
    XCTAssertEqual(try store.collectionFiles().count, 32)
    _ = try store.cleanRetention(at: 30 * 86400 + 164)
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertLessThan(store.collectionPeakReadBytes, 2 * 1024 * 1024)
    print("COLLECTION_BACKLOG encoded_payload_peak_bytes=\(store.collectionPeakReadBytes) records=64 text_bytes_per_record=1048576")
  }
  func testSameSecondAndRollbackOutageRecoveryMatchesCompleteFormattedInputAcrossTwelveRestarts() throws {
    func enqueue(_ pipeline: CollectionPipeline) {
      for (time, text, source) in [(100,"Invented version 1","a"),(100,"Invented version 2","b"),(99,"Invented version 3","c"),(3700,"Invented version 4","d")] {
        pipeline.offer(payload: ScreenTextPayload(text: text), at: time, source: source, documentKey: "", runID: nil, attemptID: nil)
      }
      pipeline.drain()
    }
    let baseline = store.makeCollectionPipeline(); enqueue(baseline)
    let expected = SummaryFormat().table(range: TimeRange(60, 3720), samples: [], evidence: try store.novelEvidence(in: all))
    for i in 0..<12 {
      let root = folder.appendingPathComponent("restart-\(i)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let db = try open(root)
      var pipeline: CollectionPipeline? = db.makeCollectionPipeline()
      try db.connection.run("BEGIN IMMEDIATE"); enqueue(pipeline!)
      let records = try db.collectionFiles().map { try XCTUnwrap(db.readReadyCollection($0)) }
      XCTAssertEqual(records.map(\.enqueueSequence), [1,2,3,4])
      XCTAssertEqual(records.map(\.time), [100,100,99,3700])
      try db.connection.run("ROLLBACK"); pipeline = nil
      let recovered = db.makeCollectionPipeline(); recovered.drain()
      XCTAssertEqual(SummaryFormat().table(range: TimeRange(60,3720), samples: [], evidence: try db.novelEvidence(in: all)), expected)
      recovered.offer(observation(3701)); recovered.drain()
      XCTAssertEqual(try db.collectionFiles().count, 0)
      XCTAssertEqual(try db.observations(in: all).count, 1)
    }
  }
  func testIgnoredObservationOrInputBatchInsertRetainsReadyAndRecovers() throws {
    for (i, table) in ["sample_observations", "input_batches"].enumerated() {
      let time = 100+i, pipeline = store.makeCollectionPipeline()
      try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON \(table) BEGIN SELECT RAISE(IGNORE); END")
      pipeline.offer(observation(time, events: [InputObservation(kind: .move, timestamp: Double(time))])); pipeline.drain()
      XCTAssertEqual(try store.observations(in: TimeRange(time,time+1)).count, 0)
      XCTAssertEqual(try store.collectionFiles().count, 1)
      XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
      try store.connection.run("DROP TRIGGER invented_ignore"); pipeline.drain()
      XCTAssertEqual(try store.observations(in: TimeRange(time,time+1)).count, 1)
      XCTAssertEqual(try store.inputEvents(in: TimeRange(time,time+1)).count, 1)
      XCTAssertEqual(try store.collectionFiles().count, 0)
    }
  }
  func testMismatchedExistingObservationAndInputIdentitiesCannotAcknowledge() throws {
    let original = observation(100, id: "invented-identity", events: [InputObservation(kind: .move, timestamp: 100.1)])
    try store.appendObservations([original])
    var changed = original; changed.sample.window = "Invented conflicting content"
    try store.stageCollection(CollectionRecord(observation: changed, time: 100, observationEvents: CompactInput.encode(original.sample.inputEvents)))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=1"))
    XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
    try store.eraseStagedCollection(in: all)
    var metadata = original; metadata.sample.inputEvents = []
    try store.stageCollection(CollectionRecord(observation: metadata, time: 100, observationEvents: CompactInput.encode([InputObservation(kind: .drag, timestamp: 100.1)])))
    pipeline.drain(); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=2"))
    XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
  }
  func testEventsOnlyIgnoredBatchRetainsReadyAndRecovers() throws {
    let value = observation(100), events = [InputObservation(kind: .move, timestamp: 101.5)]
    try store.stageCollection(CollectionRecord(observation: value, time: 100, observationEvents: CompactInput.encode(events), eventsOnly: true))
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON input_batches BEGIN SELECT RAISE(IGNORE); END")
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_ignore"); pipeline.drain()
    XCTAssertEqual(try store.inputEvents(in: all), events); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertEqual(try store.observations(in: all).count, 0)
  }
  func testRecorderLoopSaturatedAdmissionHasBoundedMainThreadWaitAndCountedSourceTimeLoss() throws {
    let journal = try ModelCallJournal(database: store.url)
    let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { finished.signal() }
      try! journal.withLock { acquired.signal(); _ = release.wait(timeout: .now()+2) }
    }
    XCTAssertEqual(acquired.wait(timeout: .now()+5), .success)
    let clock = FakeClock(), source = FakeSources(); clock.now = 100; source.clock = clock
    let loop = RecorderLoop(clock: clock, input: source, front: source, secure: source, awake: source, screen: source,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    let events = (0..<65_536).map { InputObservation(kind: .modifiers, timestamp: 100+Double($0)/100_000) }
    var counts = InputCounts(); counts.events = events
    source.input = .value(counts)
    let first = DispatchTime.now().uptimeNanoseconds; loop.tick()
    let firstMS = Double(DispatchTime.now().uptimeNanoseconds-first)/1_000_000
    clock.now = 101; source.input = .value(counts)
    let start = DispatchTime.now().uptimeNanoseconds; loop.tick()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
    clock.now = 102; source.input = .value(InputCounts()); loop.tick()
    print("COLLECTION_SATURATED_TICK initial_ms=\(firstMS) saturated_ms=\(elapsed) retained_bytes=\(loop.health.collectionRetainedBytes) dropped_observations=\(loop.health.droppedObservations)")
    XCTAssertLessThan(elapsed, 250, "Saturated tick took \(elapsed) ms; initial \(firstMS) ms")
    XCTAssertGreaterThan(loop.health.droppedObservations, 0)
    XCTAssertEqual(loop.health.collectionLastDropTime, 101)
    XCTAssertNotNil(loop.health.collectionLastDropSource)
    XCTAssertEqual(loop.health.collectionLastAdmissionLosses.first?.time, 101)
    XCTAssertEqual(loop.health.collectionLastAdmissionLosses.first?.reason, "admission_deadline")
    XCTAssertEqual(loop.health.collectionLastAdmissionLosses.first?.capture, false)
    XCTAssertLessThanOrEqual(loop.health.collectionRetainedBytes, CollectionPipeline.queueBytes+CollectionPipeline.overflowBytes)
    release.signal(); XCTAssertEqual(finished.wait(timeout: .now()+5), .success)
    loop.stop()
    XCTAssertGreaterThan(try store.observations(in: all).count, 0)
  }
  func testRecorderWriterInitializationFailureIsVisibleAndRetried() throws {
    var fail = true
    store.collectionWriterFactory = {
      if fail { throw StorageError("Invented initialization failure") }
      return self.store
    }
    let clock = FakeClock(), source = FakeSources(); clock.now = 100; source.clock = clock
    let loop = RecorderLoop(clock: clock, input: source, front: source, secure: source, awake: source, screen: source,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    source.input = .value(InputCounts()); loop.tick(); loop.flush()
    XCTAssertGreaterThan(loop.health.collectionInitializationFailures, 0)
    XCTAssertGreaterThan(try CollectionOperationalHealth.read(database: store.url).initialization, 0)
    XCTAssertGreaterThan(loop.health.collectionRetainedBytes, 0)
    XCTAssertEqual(try store.observations(in: all).count, 0)
    fail = false; loop.flush(); loop.stop()
    XCTAssertEqual(try store.observations(in: all).count, 1)
    XCTAssertEqual(loop.health.collectionRetainedBytes, 0)
  }
  func testCommitTimeIngestionIncludesDelayedRecoveryAndSurvivesDeletionWithoutDoubleCounting() throws {
    store.connection.collectionCommitClock = { 200_000 }
    try store.appendObservations([observation(100)])
    let bytes = try store.connection.integer("SELECT bytes FROM collection_ingestion WHERE committed_ts=200000")
    XCTAssertGreaterThan(bytes, 0)
    let status = try store.collectionStatus(at: 200_000)
    XCTAssertTrue(status.contains("sample_observations_retained_occurrence_24h_bytes=0"))
    XCTAssertTrue(status.contains("collection_ingested_commit_24h_bytes=\(bytes)"))
    XCTAssertThrowsError(try store.connection.transaction {
      try store.insertObservation(observation(101))
      throw StorageError("Invented rollback")
    })
    XCTAssertEqual(try store.connection.integer("SELECT bytes FROM collection_ingestion WHERE committed_ts=200000"), bytes)
    let range = TimeRange(100,101), preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertTrue(try store.collectionStatus(at: 200_000).contains("collection_ingested_commit_24h_bytes=\(bytes)"))
    XCTAssertTrue(try store.collectionStatus(at: 300_000).contains("collection_ingested_commit_24h_bytes=0"))
  }
  func testRetentionRepairsNoveltyInBoundedTransactionsAndRefusesFailedProof() throws {
    store.noveltyKeyReader = { _ in throw StorageError("Invented rebuild outage") }
    for time in 100..<197 { try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented version \(time)"), at: time, source: "invented", documentKey: "", project: "", probe: nil) }
    XCTAssertThrowsError(try store.novelEvidence(in: all))
    store.noveltyKeyReader = nil
    var pendingAtCommit: [Int] = []
    store.connection.collectionCommitClock = {
      pendingAtCommit.append(try! self.store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"))
      return 200_000
    }
    _ = try store.cleanRetention(at: 30*86400+99)
    XCTAssertEqual(Array(pendingAtCommit.prefix(4)), [65,33,1,0])
    XCTAssertNoThrow(try store.novelEvidence(in: all))
    try store.connection.run("UPDATE screen_payloads SET novel_text=NULL WHERE evidence_id=1")
    try store.connection.run("CREATE TRIGGER invented_ignore_repair BEFORE UPDATE OF novel_text ON screen_payloads BEGIN SELECT RAISE(IGNORE); END")
    XCTAssertThrowsError(try store.cleanRetention(at: 31*86400+100))
    XCTAssertEqual(try store.evidence(in: all).count, 97)
    XCTAssertThrowsError(try store.novelEvidence(in: all))
  }
  func testProductionRetentionPlansAndDurationAtThirtyActiveDays() throws {
    let rows = 30 * 38_400
    let payload = String(decoding: try JSONEncoder().encode(observation(0, id: "invented")), as: UTF8.self)
    let started = DispatchTime.now().uptimeNanoseconds
    // Generate invented history directly; the measured public maintenance API
    // below must install its own scoped contract, not inherit a fixture proof.
    try store.connection.run("BEGIN IMMEDIATE")
    do {
      for day in 0..<30 {
        try store.connection.run("""
          WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<38399)
          INSERT INTO sample_observations(observation_id,ts,payload,observed_ts)
          SELECT 'invented-'||(?1*38400+x),?1*86400+x*3/4,
            json_set(?2,'$.id','invented-'||(?1*38400+x),'$.sample.ts',?1*86400+x*3/4),?1*86400+x*3/4 FROM n
          """, [.integer(day), .maskedText(payload)])
      }
      try store.connection.run("COMMIT")
    } catch {
      try? store.connection.run("ROLLBACK")
      throw error
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), rows)
    var plans: [String] = []
    for sql in ["DELETE FROM sample_observations WHERE id IN (" + ActivityStorage.expiredCollectionObservations + ")", "SELECT EXISTS(" + ActivityStorage.expiredCollectionObservations + ")"] {
      var details = ""
      try store.connection.namedRows("EXPLAIN QUERY PLAN " + sql, [.integer(86400)]) { details += try $0.text("detail") + "\n" }
      XCTAssertTrue(details.contains("sample_observations_time"), details)
      XCTAssertTrue(details.contains("sample_observations_observed"), details)
      XCTAssertTrue(details.contains("collection_legacy_time"), details)
      XCTAssertTrue(details.contains("sample_observations_legacy"), details)
      XCTAssertFalse(details.contains("SCAN sample_observations\n"), details)
      plans.append(details)
    }
    let cleanStart = DispatchTime.now().uptimeNanoseconds
    _ = try store.cleanRetention(at: 31*86400)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds-cleanStart)/1_000_000
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), rows-38_400)
    print("COLLECTION_30DAY rows=\(rows) expired=38400 retention_ms=\(elapsed) fixture_seconds=\(Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000_000)")
    print("COLLECTION_RETENTION_PLANS\n" + plans.joined(separator: "\n"))
  }

  func testMoreThanOneBatchOfDamagedReadyFilesCannotDelayValidWork() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    for i in 0..<65 { try Data("{".utf8).write(to: store.collectionDirectory.appendingPathComponent(String(format: "%020d-damaged.json", i))) }
    try store.stageCollection(CollectionRecord(observation: observation(100), time: 100))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 1)
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertTrue(try store.collectionStatus().contains("collection_quarantined_rows=65"))
    let preview = try store.previewDeletion(in: TimeRange(100,101))
    XCTAssertEqual(preview.counts["staged_collection"], 65)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertTrue(try store.collectionStatus().contains("collection_quarantined_rows=0"))
  }
  func testTimestampTypeProofCannotConfuseNullOrTextWithZero() throws {
    var value = observation(0); value.sample.observedAt = 0
    try store.connection.run("CREATE TRIGGER invented_bad_time AFTER INSERT ON sample_observations BEGIN UPDATE sample_observations SET observed_ts=NULL WHERE id=NEW.id; END")
    let pipeline = store.makeCollectionPipeline(); pipeline.offer(value); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    XCTAssertEqual(try store.observations(in: all).count, 0)
    try store.connection.run("DROP TRIGGER invented_bad_time"); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 0)
    try store.connection.run("CREATE TRIGGER invented_bad_batch_time AFTER INSERT ON input_batches BEGIN UPDATE input_batches SET ts='invalid' WHERE id=NEW.id; END")
    pipeline.offer(observation(1, events: [InputObservation(kind: .move, timestamp: 0.5)])); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    XCTAssertEqual(try store.inputEvents(in: all).count, 0)
    try store.connection.run("DROP TRIGGER invented_bad_batch_time"); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertEqual(try store.inputEvents(in: all).count, 1)
  }

  func testQuarantineNameCollisionPreservesBothDamagedCopiesUntilForget() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    let file = store.collectionDirectory.appendingPathComponent("damaged.json")
    for content in ["{", "{x"] {
      try Data(content.utf8).write(to: file)
      XCTAssertNil(try store.readReadyCollection(file))
    }
    XCTAssertTrue(try store.collectionStatus().contains("collection_quarantined_rows=2"))
    let preview = try store.previewDeletion(in: TimeRange(100,101))
    XCTAssertEqual(preview.counts["staged_collection"], 2)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertTrue(try store.collectionStatus().contains("collection_quarantined_rows=0"))
  }

  func testUnreadableSequenceCannotResetOrderingOrDiscardAcceptedWork() throws {
    let pipeline = CollectionPipeline(writer: store)
    pipeline.offer(observation(100)); pipeline.drain()
    let counter = store.collectionDirectory.appendingPathComponent(".sequence")
    let first = try Data(contentsOf: counter)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: counter.path)
    XCTAssertTrue(pipeline.offer(observation(101))); pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 1)
    XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: counter.path)
    pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 2)
    XCTAssertEqual(String(decoding: first, as: UTF8.self), "1")
    XCTAssertEqual(String(decoding: try Data(contentsOf: counter), as: UTF8.self), "2")
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }

}
