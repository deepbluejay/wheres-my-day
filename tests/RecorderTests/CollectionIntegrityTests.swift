import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionIntegrityTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  let all = TimeRange(0, 1000)
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func value(_ id: String = UUID().uuidString) -> ActivityObservation {
    ActivityObservation(id: id, sample: TimeSample(ts: 101, bundleID: "invented", window: "Invented metadata",
      inputEvents: [InputObservation(kind: .move, timestamp: 100.9)], observedAt: 100.5))
  }
  func damaged(_ kind: Int, eventsOnly: Bool) throws -> Data {
    var record = CollectionRecord(observation: value(), time: 101, eventsOnly: eventsOnly)
    switch kind {
    case 0: record.time = Int.max; record.observation?.sample.ts = Int.max
    case 1: record.observation?.sample.ts = 102
    case 2:
      record.observation?.sample.inputEvents = []
      record.observationEvents = CompactInput.encode([InputObservation(kind: .move, timestamp: .nan)])
    case 3:
      record.observation?.sample.inputEvents = []
      record.observationEvents = CompactInput.encode([InputObservation(kind: .move, timestamp: .infinity)])
    case 4: record.observation?.sample.observedAt = Double(Int.max)
    case 5:
      record.observation?.sample.inputEvents = []
      var bytes = CompactInput.encode([InputObservation(kind: .move, timestamp: 100.9)])
      bytes[3] |= 128; record.observationEvents = bytes
    case 6:
      record = CollectionRecord(screen: ScreenTextPayload(text: "Invented", document: "invented"), time: Int.max-1, eventsOnly: eventsOnly)
    case 7:
      record = CollectionRecord(screen: ScreenTextPayload(text: "Invented"), time: 101,
        screenJSON: try screenPayloadJSON(ScreenTextPayload(text: "Invented different")), eventsOnly: eventsOnly)
    case 8: record.observationEvents = CompactInput.encode([InputObservation(kind: .move, timestamp: 90)])
    case 9:
      record = CollectionRecord(screen: ScreenTextPayload(text: "Invented"), time: 101,
        observationEvents: CompactInput.encode([]), eventsOnly: eventsOnly)
    default: record.screen = ScreenTextPayload(text: "Invented")
    }
    return try JSONEncoder().encode(record)
  }
  func write(_ data: Data, name: String = "000-damaged.json") throws -> URL {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    let file = store.collectionDirectory.appendingPathComponent(name)
    try data.write(to: file); return file
  }
  func testSemanticDamageCannotStarveNormalOrEventsOnlyRecoveryAndIsAlwaysPrivacyVisible() throws {
    for eventsOnly in [false, true] {
      for kind in 0..<11 {
        let file = try write(damaged(kind, eventsOnly: eventsOnly))
        let unrelated = try store.previewDeletion(in: TimeRange(900,901))
        XCTAssertEqual(unrelated.counts["staged_collection"], 1)
        try store.stageCollection(CollectionRecord(observation: value(), time: 101))
        let pipeline = CollectionPipeline(writer: store); pipeline.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try store.collectionFiles().isEmpty)
        XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
        XCTAssertEqual(try store.previewDeletion(in: TimeRange(900,901)).counts["staged_collection"], 1)
        XCTAssertThrowsError(try store.deleteRecords(in: unrelated.range, confirmation: unrelated.confirmation))
        let fresh = try store.previewDeletion(in: unrelated.range)
        try store.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
        XCTAssertEqual(try store.previewDeletion(in: fresh.range).counts["staged_collection"], 0)
      }
    }
    XCTAssertEqual(try store.observations(in: all).count, 22)
    XCTAssertEqual(try store.inputEvents(in: all).count, 22)
  }
  func testSemanticReadyDamageForgetRetentionAndByteFreshness() throws {
    for eventsOnly in [false, true] {
      for kind in 0..<11 {
        let data = try damaged(kind, eventsOnly: eventsOnly), file = try write(data)
        let preview = try store.previewDeletion(in: TimeRange(800,801))
        var changed = data; changed.append(32); try changed.write(to: file)
        XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
        let fresh = try store.previewDeletion(in: preview.range)
        try store.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try data.write(to: file)
        _ = try store.cleanRetention(at: 30*86400+10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try data.write(to: file); _ = try store.readReadyCollection(file)
        _ = try store.cleanRetention(at: 30*86400+10)
        XCTAssertEqual(try store.previewDeletion(in: TimeRange(800,801)).counts["staged_collection"], 0)
      }
    }
  }
  func testInvalidDirectAndInitialStagingRejectWithoutQuarantine() throws {
    var invalid = value(); invalid.sample.inputEvents[0].timestamp = .nan
    XCTAssertThrowsError(try store.appendObservations([invalid]))
    XCTAssertThrowsError(try store.stageCollection(CollectionRecord(observation: value(), time: 102)))
    XCTAssertThrowsError(try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented"), at: Int.max, source: "invented", documentKey: "", project: "", probe: nil))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.collectionQuarantine.path))
  }
  func historicalOff() throws {
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 101)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 102)
  }
  func testLateMetadataDeletionMutationAndExtraInputRollbackDirectAndRecovery() throws {
    let actions = ["DELETE FROM input_batches", "UPDATE input_batches SET events=X'0100'",
      "INSERT INTO input_batches(observation_id,ts,events) VALUES(NEW.identity,99,X'0100')"]
    for (index, action) in actions.enumerated() {
      let observation = value("invented-late-\(index)")
      try store.stageCollection(CollectionRecord(observation: observation, time: 101))
      try historicalOff()
      try store.connection.run("CREATE TRIGGER invented_late AFTER INSERT ON collection_metadata BEGIN \(action); END")
      XCTAssertThrowsError(try store.appendObservations([observation]))
      let pipeline = store.makeCollectionPipeline(); pipeline.drain(); pipeline.drain()
      XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
      XCTAssertEqual(try store.collectionFiles().count, 1)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches WHERE observation_id=?", [.key(observation.id)]), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE identity=?", [.key(observation.id)]), 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.collectionQuarantine.path))
      try store.connection.run("DROP TRIGGER invented_late")
      let restarted = store.makeCollectionPipeline(); restarted.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(try store.inputEvents(in: all).count, index+1)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), index+1)
    }
  }
  func testNormalParentMutationByInputRollsBackDirectAndRecovery() throws {
    for action in ["DELETE FROM sample_observations", "UPDATE sample_observations SET payload='{}'",
      "INSERT INTO input_batches(observation_id,ts,events) VALUES(NEW.observation_id,99,X'0100')",
      "INSERT INTO collection_legacy_times(observation_row,ts) SELECT id,99 FROM sample_observations",
      "UPDATE sample_observations SET payload=json_set(payload,'$.invented_extra','Invented mutation')"] {
      let observation = value()
      try store.stageCollection(CollectionRecord(observation: observation, time: 101))
      try store.connection.run("CREATE TRIGGER invented_late AFTER INSERT ON input_batches BEGIN \(action); END")
      XCTAssertThrowsError(try store.appendObservations([observation]))
      let pipeline = store.makeCollectionPipeline(); pipeline.drain()
      XCTAssertEqual(try store.collectionFiles().count, 1)
      try store.connection.run("DROP TRIGGER invented_late")
      let restarted = store.makeCollectionPipeline(); restarted.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
    }
    XCTAssertEqual(try store.observations(in: all).count, 5)
  }
  func testInverseInputMutationOfExistingIndependentMetadataRollsBack() throws {
    let observation = value("invented-inverse")
    try historicalOff()
    try store.appendObservations([observation])
    try store.stageCollection(CollectionRecord(observation: observation, time: 101))
    try store.connection.run("CREATE TRIGGER invented_late BEFORE INSERT ON input_batches BEGIN UPDATE collection_metadata SET payload='{}' WHERE identity=NEW.observation_id; END")
    XCTAssertThrowsError(try store.appendObservations([observation]))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_late"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.inputEvents(in: all).count, 1)
  }
  func testReplayCannotAcceptUnknownJSONFieldsAddedDuringAnIdempotentChildWrite() throws {
    let observation = value()
    try store.appendObservations([observation])
    try store.stageCollection(CollectionRecord(observation: observation, time: 101))
    try store.connection.run("CREATE TRIGGER invented_late BEFORE INSERT ON input_batches BEGIN UPDATE sample_observations SET payload=json_set(payload,'$.invented_extra','Invented mutation'); END")
    XCTAssertThrowsError(try store.appendObservations([observation]))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_late"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.observations(in: all).count, 1)
  }
  func testFinalProofRunsAfterLaterRecordsAndCommitAccountingTriggers() throws {
    let first = value("invented-first"), second = value("invented-second")
    try store.connection.run("CREATE TRIGGER invented_late AFTER INSERT ON sample_observations WHEN NEW.observation_id='invented-second' BEGIN DELETE FROM input_batches WHERE observation_id='invented-first'; END")
    XCTAssertThrowsError(try store.appendObservations([first, second]))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
    try store.connection.run("DROP TRIGGER invented_late")
    try store.connection.run("CREATE TRIGGER invented_late AFTER UPDATE ON collection_ingestion_pending WHEN NEW.bytes=0 BEGIN DELETE FROM input_batches; END")
    XCTAssertThrowsError(try store.appendObservations([first]))
    try store.stageCollection(CollectionRecord(observation: first, time: 101))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_late"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.inputEvents(in: all).count, 1)
  }
  func testUnexpectedIndependentMetadataCannotBeAcknowledgedByNormalRecovery() throws {
    let observation = value()
    try store.stageCollection(CollectionRecord(observation: observation, time: 101))
    try store.connection.run("CREATE TRIGGER invented_late AFTER INSERT ON input_batches BEGIN INSERT INTO collection_metadata(identity,ts,source,document_key,payload) VALUES(NEW.observation_id,100,'invented','','{}'); END")
    XCTAssertThrowsError(try store.appendObservations([observation]))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_late"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
  }
  func testCaptureProofSurvivesAllLateWritesInNormalAndEventsOnlyTransactions() throws {
    for (index, action) in [
      "DELETE FROM screen_payloads",
      "UPDATE collection_blobs SET content='Invented mutation'",
      "DELETE FROM collection_metadata",
      "UPDATE collection_metadata SET payload='{}'",
    ].enumerated() {
      let parent = 201+index*10
      let record = CollectionRecord(screen: ScreenTextPayload(text: "Invented capture", document: "invented"),
        time: parent, source: "invented", occurrenceID: "invented-capture-\(index)", metadataObservedAt: Double(parent)-0.5)
      try store.stageCollection(record)
      if index >= 2 {
        try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: parent)
        try store.saveSettings(StorageSettings(excludedApps: []), at: parent+1)
      }
      try store.connection.run("CREATE TRIGGER invented_late AFTER UPDATE ON collection_ingestion_pending WHEN NEW.bytes=0 BEGIN \(action); END")
      XCTAssertThrowsError(try store.storeScreenCapture(text: record.screen!.text, at: parent, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: record.screen, occurrenceID: record.occurrenceID, metadataObservedAt: record.metadataObservedAt))
      let pipeline = store.makeCollectionPipeline(); pipeline.drain()
      XCTAssertEqual(try store.collectionFiles().count, 1)
      XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
      try store.connection.run("DROP TRIGGER invented_late")
      let restarted = store.makeCollectionPipeline(); restarted.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
    }
    XCTAssertEqual(try store.evidence(in: all).count, 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 2)
  }
  func testPolicyReadFailureRetriesValidReadyWithoutQuarantiningIt() throws {
    try store.stageCollection(CollectionRecord(observation: value(), time: 101))
    try store.connection.run("ALTER TABLE collection_retention RENAME TO invented_unavailable")
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.collectionQuarantine.path))
    try store.connection.run("ALTER TABLE invented_unavailable RENAME TO collection_retention")
    pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.inputEvents(in: all).count, 1)
  }
  func testRecoveryCursorMeasurements51220488192Records() throws {
    let encoded = try JSONEncoder().encode(CollectionRecord(observation: value("invented-replay"), time: 101))
    for count in [512,2048,8192] {
      for index in 0..<count { _ = try write(encoded, name: String(format: "r-%020d.json", index)) }
      let visits = store.collectionEnumerationVisits, start = DispatchTime.now().uptimeNanoseconds
      let pipeline = CollectionPipeline(writer: store)
      for _ in 0..<(count/32+1) { pipeline.drain() }
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
      XCTAssertEqual(store.collectionEnumerationVisits-visits, count)
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      print("COLLECTION_RECOVERY_CURSOR records=\(count) leaf_visits=\(store.collectionEnumerationVisits-visits) drain_ms=\(elapsed)")
    }
    XCTAssertEqual(try store.observations(in: all).count, 1)
  }
  func testRecoveryCursorDetectsNewPublicationAndSurvivesPrivacyErasure() throws {
    for index in 0..<80 { try store.stageCollection(CollectionRecord(observation: value("invented-order-\(index)"), time: 101)) }
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    try store.stageCollection(CollectionRecord(observation: value("invented-new"), time: 101))
    for _ in 0..<4 { pipeline.drain() }
    var identities: [String] = []
    try store.connection.namedRows("SELECT observation_id FROM sample_observations ORDER BY id") { identities.append(try $0.text("observation_id")) }
    XCTAssertEqual(identities, (0..<80).map { "invented-order-\($0)" } + ["invented-new"])
    for _ in 0..<80 { try store.stageCollection(CollectionRecord(observation: value(), time: 101)) }
    pipeline.drain()
    let preview = try store.previewDeletion(in: TimeRange(100,102))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    for _ in 0..<4 { pipeline.drain() }
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertTrue(try store.observations(in: all).isEmpty)
  }
}
