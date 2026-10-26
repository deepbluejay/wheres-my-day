import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionTransactionProofTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  let all = TimeRange(0, 1000)
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
  func observation(_ id: String = UUID().uuidString) -> ActivityObservation {
    ActivityObservation(id: id, sample: TimeSample(ts: 101, bundleID: "invented", window: "Invented", inputEvents: [InputObservation(kind: .move, timestamp: 100.5)], observedAt: 100.5))
  }
  func hex(_ events: [InputObservation]) -> String { CompactInput.encode(events).map { String(format: "%02x", $0) }.joined() }
  func assertRecoveryFailureThenRetry(_ record: CollectionRecord) throws {
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_fault")
    try reopen()
    let restarted = store.makeCollectionPipeline(); restarted.drain()
    XCTAssertEqual(restarted.takeDiagnostics().persistenceFailures, 0)
    XCTAssertTrue(try store.collectionFiles().isEmpty)
  }
  func testTransactionEntryInputBaselineAcrossPoliciesRoutesAndControls() throws {
    // Each cell has its own database, so no committed history can hide an injection.
    for route in 0..<3 { for policy in 0..<4 { for fault in [false, true] {
      let child = CollectionTransactionProofTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      var value = child.observation("invented-matrix")
      if route == 2 { value.sample.inputEvents.append(InputObservation(kind: .move, timestamp: 101.5)) }
      let record = CollectionRecord(observation: value, time: 101, eventsOnly: route == 2)
      if route > 0 { try child.store.stageCollection(record) }
      switch policy {
      case 0:
        try child.store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 99)
        try child.store.saveSettings(StorageSettings(excludedApps: []), at: 100)
      case 1:
        let preview = try child.store.previewDeletion(in: TimeRange(99,100))
        try child.store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      case 2: try child.store.saveSettings(StorageSettings(excludedApps: ["invented"]), at: 103)
      default: try child.store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 103)
      }
      // eventsOnly also exercises injection from refusal accounting before the helper.
      if route == 2 {
        try child.store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 101)
        try child.store.saveSettings(StorageSettings(excludedApps: policy == 2 ? ["invented"] : [], recordingEnabled: policy != 3), at: 102)
      }
      if fault {
        let table = route == 2 || policy >= 2 ? "collection_policy_refusals" : "sample_observations"
        let bytes = child.hex([InputObservation(kind: .move, timestamp: 99.5)])
        try child.store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON \(table) BEGIN INSERT OR IGNORE INTO input_batches(observation_id,ts,events) VALUES('invented-matrix',99,X'\(bytes)'); END")
      }
      if route == 0 {
        if fault { XCTAssertThrowsError(try child.store.appendObservations([value])) }
        else { try child.store.appendObservations([value]) }
      } else {
        let pipeline = child.store.makeCollectionPipeline(); pipeline.drain()
        XCTAssertEqual(try child.store.collectionFiles().count, fault ? 1 : 0)
        XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures > 0, fault)
      }
      XCTAssertEqual(try child.store.inputEvents(in: TimeRange(99,100)).count, 0)
      if fault {
        XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM input_batches"), 0)
        try child.store.connection.run("DROP TRIGGER invented_fault")
        try child.reopen()
        if route == 0 { try child.store.appendObservations([value]) }
        else { let retry = child.store.makeCollectionPipeline(); retry.drain(); XCTAssertTrue(try child.store.collectionFiles().isEmpty) }
      }
      XCTAssertEqual(try child.store.inputEvents(in: TimeRange(99,100)).count, 0)
      XCTAssertEqual(try child.store.inputEvents(in: TimeRange(100,101)).count, policy < 2 ? 1 : 0)
    } } }
  }
  func testEarlierRecordCannotSeedLaterIdentityAndRequiredHistoryCannotDisappear() throws {
    let first = observation("invented-first"), second = observation("invented-second")
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 99)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 100)
    let bytes = hex([InputObservation(kind: .move, timestamp: 99.5)])
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON sample_observations WHEN NEW.observation_id='invented-first' BEGIN INSERT INTO input_batches(observation_id,ts,events) VALUES('invented-second',99,X'\(bytes)'); END")
    XCTAssertThrowsError(try store.appendObservations([first, second]))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
    try store.connection.run("DROP TRIGGER invented_fault")
    try reopen()
    try store.appendObservations([first, second])
    var replay = second; replay.sample.inputEvents = []
    try store.connection.run("CREATE TRIGGER invented_fault BEFORE INSERT ON sample_observations BEGIN DELETE FROM input_batches WHERE observation_id='invented-second'; END")
    XCTAssertThrowsError(try store.appendObservations([replay]))
    XCTAssertEqual(try store.inputEvents(in: all).count, 2)
    try store.connection.run("DROP TRIGGER invented_fault")
    try store.appendObservations([replay])
  }
  func testMultiSecondInputProofDetectsMutationOfAnEarlierAdmittedBatch() throws {
    var value = observation()
    value.sample.ts = 500
    value.sample.observedAt = nil
    value.sample.inputEvents = (100..<228).map { InputObservation(kind: .move, timestamp: Double($0)+0.5) }
    let record = CollectionRecord(observation: value, time: 500)
    try store.stageCollection(record)
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON input_batches WHEN NEW.ts=227 BEGIN UPDATE input_batches SET events=X'0100' WHERE observation_id=NEW.observation_id AND ts=100; END")
    XCTAssertThrowsError(try store.appendObservations([value]))
    try assertRecoveryFailureThenRetry(record)
    XCTAssertEqual(try store.inputEvents(in: all), value.sample.inputEvents)
  }
  func testCaptureCannotInjectAnAbsentInputComponent() throws {
    let record = CollectionRecord(screen: ScreenTextPayload(text: "Invented"), time: 101, source: "invented", occurrenceID: "invented-capture")
    try store.stageCollection(record)
    let bytes = hex([InputObservation(kind: .move, timestamp: 99.5)])
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON screen_payloads BEGIN INSERT INTO input_batches(observation_id,ts,events) VALUES(NEW.occurrence_id,99,X'\(bytes)'); END")
    try assertRecoveryFailureThenRetry(record)
    XCTAssertEqual(try store.inputEvents(in: all).count, 0)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }
  func testEveryNewObservationColumnIsExpectedAndMetadataForgetPreservesParent() throws {
    for mutation in ["legacy_timing=1", "legacy_timing=1.5", "id=id+1000", "observation_id=observation_id||'-changed'", "ts=102", "observed_ts=99", "payload=json_set(payload,'$.invented',1)"] {
      let value = observation()
      let record = CollectionRecord(observation: value, time: 101)
      try store.stageCollection(record)
      try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON input_batches BEGIN UPDATE sample_observations SET \(mutation) WHERE observation_id=NEW.observation_id; END")
      XCTAssertThrowsError(try store.appendObservations([value]))
      try assertRecoveryFailureThenRetry(record)
      XCTAssertEqual(try store.connection.integer("SELECT legacy_timing FROM sample_observations WHERE observation_id=?", [.key(value.id)]), 0)
    }
    let preview = try store.previewDeletion(in: TimeRange(100,101))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.observations(in: all).count, 7)
    XCTAssertTrue(try store.observations(in: all).allSatisfy { $0.sample.observedAt == nil })
  }
  func testNewScreenAndBlobColumnsAreExpectedAndHistoricalDedupClockIsStable() throws {
    for (index, mutation) in ["UPDATE evidence SET source_id='invented-mutated' WHERE id=NEW.evidence_id",
      "UPDATE screen_payloads SET novelty_rebuild_failed=1 WHERE evidence_id=NEW.evidence_id",
      "UPDATE collection_blobs SET created_ts=999",
      "UPDATE collection_blobs SET content='Invented changed'"].enumerated() {
      let record = CollectionRecord(screen: ScreenTextPayload(text: "Invented \(index)"), time: 101+index, source: "invented", occurrenceID: "invented-screen-\(index)")
      try store.stageCollection(record)
      try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON screen_payloads BEGIN \(mutation); END")
      XCTAssertThrowsError(try store.storeScreenCapture(text: record.screen!.text, at: record.time, source: record.source, documentKey: "", project: "", knownKeys: [], probe: nil, payload: record.screen, occurrenceID: record.occurrenceID))
      try assertRecoveryFailureThenRetry(record)
    }
    let payload = ScreenTextPayload(text: "Invented 0")
    try store.appendScreenCapture(payload: payload, at: 200, source: "invented", documentKey: "", project: "", probe: nil)
    XCTAssertEqual(try store.connection.integer("SELECT created_ts FROM collection_blobs WHERE hash=?", [.key(probeHash(payload.text))]), 101)
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON evidence BEGIN UPDATE collection_blobs SET created_ts=201; END")
    XCTAssertThrowsError(try store.appendScreenCapture(payload: payload, at: 201, source: "invented", documentKey: "", project: "", probe: nil))
    try store.connection.run("DROP TRIGGER invented_fault")
    XCTAssertEqual(try store.connection.integer("SELECT created_ts FROM collection_blobs WHERE hash=?", [.key(probeHash(payload.text))]), 101)
  }
  func testGeneratedInputMetadataIdentitiesAndUnexpectedRefusalRowsAreRejected() throws {
    for (table, action) in [("input_batches", "UPDATE input_batches SET id=id+1000 WHERE id=NEW.id"),
      ("collection_metadata", "UPDATE collection_metadata SET id=id+1000 WHERE id=NEW.id"),
      ("sample_observations", "INSERT INTO collection_policy_refusals(reason,count) VALUES('invented-extra',1)")] {
      let value = observation()
      let record = CollectionRecord(observation: value, time: 101, eventsOnly: table == "collection_metadata")
      try store.stageCollection(record)
      try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON \(table) BEGIN \(action); END")
      try assertRecoveryFailureThenRetry(record)
    }
  }
}
