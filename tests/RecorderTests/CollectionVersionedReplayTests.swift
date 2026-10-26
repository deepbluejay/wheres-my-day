import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionVersionedReplayTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func record(_ kind: Int, version: Int? = 14) -> CollectionRecord {
    var observation = ActivityObservation(id: "invented-observation", sample: TimeSample(ts: 100, bundleID: "invented.app",
      document: "Invented document", inputEvents: [InputObservation(kind: .move, timestamp: 100.2)], observedAt: 102.2)).redacted()
    let events = CompactInput.encode(observation.sample.inputEvents); observation.sample.inputEvents = []
    if kind == 0 {
      return CollectionRecord(screen: ScreenTextPayload(text: "Invented screen"), time: 100, source: "invented.app",
        occurrenceID: "invented-occurrence", applicationPrivacyIdentity: ApplicationPrivacyIdentity.digest("invented.app"), storageVersion: version)
    }
    return CollectionRecord(observation: observation, time: 100, observationEvents: kind == 1 ? events : nil,
      eventsOnly: kind == 2 ? true : nil, storageVersion: version)
  }
  func commit(_ record: CollectionRecord) throws {
    try store.connection.transaction {
      try store.withCollectionAdmission(record) { allowed in
        if allowed.observation != nil { _ = try store.insertAdmittedObservation(allowed) }
        else { _ = try store.insertAdmittedScreen(allowed, project: "", probe: nil) }
      }
    }
  }
  func table(_ kind: Int) -> String { ["evidence", "input_batches", "collection_metadata"][kind] }
  func advance(_ pipeline: CollectionPipeline) throws {
    XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented later screen"), at: 200,
      source: "invented.other", documentKey: "", runID: nil, attemptID: nil))
    pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE ts=200"), 1)
  }
  func testEnvelopesPersistVersionAndDecodeUnversionedHistory() throws {
    let value = record(0)
    let bytes = try JSONEncoder().encode(value)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(object["storageVersion"] as? Int, 14)
    object.removeValue(forKey: "storageVersion")
    let legacy = try JSONDecoder().decode(CollectionRecord.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.storageVersion)
    XCTAssertTrue(legacy.matchesStoredIdentity(nil, incoming: "invented-digest"))
    XCTAssertFalse(legacy.matchesStoredIdentity("invented-other", incoming: "invented-digest"))
    XCTAssertFalse(value.matchesStoredIdentity(nil, incoming: "invented-digest"))
  }
  func testLegacyObservationSerializationUsesItsOriginalFields() throws {
    var value = record(1, version: nil)
    value.observation?.sample.applicationPrivacyIdentity = nil
    let allowed = try store.admitCollection(value).record
    XCTAssertEqual(allowed.storageVersion, 13)
    XCTAssertNotNil(allowed.observation?.sample.applicationPrivacyIdentity)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(allowed.observationJSON(allowed.observation!).utf8)) as? [String: Any])
    XCTAssertNil((json["sample"] as? [String: Any])?["applicationPrivacyIdentity"])
    try commit(value)
    try store.stageCollection(value)
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertTrue(try store.collectionFiles().isEmpty)
  }
  func testHistoricalScreenPrivacyUsesStoredLabelWithoutBorrowingIncomingDigest() throws {
    let owner = "invented.AKIA0123456789ABCDEF", other = "invented.AKIAFEDCBA0987654321"
    var original = record(0, version: 13)
    original.source = Redaction.applyKnownSecrets(owner).text
    original.applicationPrivacyIdentity = ApplicationPrivacyIdentity.digest(owner)
    try commit(original)
    try store.connection.run("UPDATE evidence SET application_identity=NULL")
    try store.saveSettings(StorageSettings(excludedApps: [owner]), at: 150)
    var collision = original; collision.applicationPrivacyIdentity = ApplicationPrivacyIdentity.digest(other)
    try store.stageCollection(collision)
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 1)
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=1"))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE application_identity IS NULL"), 1)
    try advance(pipeline)
  }
  func testHistoricalNullIdentityReplayPreservesRowsForEveryComponent() throws {
    for kind in 0..<3 {
      let value = record(kind, version: kind == 0 ? nil : 13)
      try commit(value)
      try store.connection.run("UPDATE \(table(kind)) SET application_identity=NULL")
      try store.stageCollection(value)
      let pipeline = CollectionPipeline(writer: store); pipeline.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table(kind)) WHERE application_identity IS NULL"), 1)
    }
  }
  func testLegacyInputMissingOwnershipIsExplicitlyRefusedWithoutReassigningIt() throws {
    let value = record(1, version: 13)
    try commit(value)
    try store.connection.run("UPDATE input_batches SET application_identity=NULL")
    try store.stageCollection(value)
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches WHERE application_identity IS NULL"), 1)
    XCTAssertTrue(try store.collectionStatus().contains("input_batch_application_identity_unavailable="))
    XCTAssertGreaterThan(try store.connection.integer("SELECT COALESCE(sum(count),0) FROM collection_policy_refusals WHERE reason='input_batch_application_identity_unavailable'"), 0)
  }
  func testLegacyMetadataPrivacyUsesItsOwnStoredLabelBeforeAcknowledgement() throws {
    let owner = "invented.AKIA0123456789ABCDEF", other = "invented.AKIAFEDCBA0987654321"
    var value = CollectionRecord(screen: ScreenTextPayload(text: "", document: "Invented document"), time: 100,
      source: Redaction.applyKnownSecrets(owner).text, documentKey: "invented-group", eventsOnly: true,
      occurrenceID: "invented-metadata", metadataObservedAt: 102.2,
      applicationPrivacyIdentity: ApplicationPrivacyIdentity.digest(owner), storageVersion: 13)
    try store.connection.transaction { try store.withCollectionAdmission(value) { try store.insertIndependentMetadata($0) } }
    try store.connection.run("UPDATE collection_metadata SET application_identity=NULL")
    try store.saveSettings(StorageSettings(excludedApps: [owner]), at: 150)
    value.applicationPrivacyIdentity = ApplicationPrivacyIdentity.digest(other)
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: store.collectionDirectory.appendingPathComponent("invented-legacy.json"))
    let pipeline = CollectionPipeline(writer: store); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE application_identity IS NULL"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count FROM collection_policy_refusals WHERE reason='metadata_excluded_app'"), 1)
    try advance(pipeline)
  }
  func testCurrentVersionNullIdentityIsUnrecoverableAndLaterWorkAdvances() throws {
    for kind in 0..<3 {
      let value = record(kind)
      try commit(value)
      try store.connection.run("UPDATE \(table(kind)) SET application_identity=NULL")
      try store.stageCollection(value)
      let pipeline = CollectionPipeline(writer: store); pipeline.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 1)
    }
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=3"))
    XCTAssertEqual(try store.previewDeletion(in: TimeRange(900,901)).counts["staged_collection"], 3)
    try advance(CollectionPipeline(writer: store))
    let preview = try store.previewDeletion(in: TimeRange(900,901))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertTrue(try store.collectionStatus().contains("collection_quarantined_rows=0"))
  }
  func testFutureAddedColumnsDoNotBecomeOldEnvelopeRequirements() throws {
    for kind in 0..<3 {
      let value = record(kind)
      try commit(value)
      try store.connection.run("ALTER TABLE \(table(kind)) ADD COLUMN invented_future_column TEXT")
      try store.stageCollection(value)
      let pipeline = CollectionPipeline(writer: store); pipeline.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table(kind)) WHERE invented_future_column IS NULL"), 1)
    }
    try advance(CollectionPipeline(writer: store))
  }
  func testUnprovableWriteQuarantinesAfterEightAttemptsAcrossColdWriters() throws {
    try store.stageCollection(record(0))
    try store.connection.run("CREATE TRIGGER invented_block BEFORE INSERT ON evidence WHEN NEW.ts=100 BEGIN SELECT RAISE(IGNORE); END")
    for attempt in 1...8 {
      let cold = try ActivityStorage(url: store.url, appDataDirectory: folder, databaseScope: .directory(folder))
      let pipeline = CollectionPipeline(writer: cold); pipeline.drain()
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 1)
      XCTAssertEqual(try store.collectionFiles().count, attempt < 8 ? 1 : 0)
    }
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=1"))
    try advance(CollectionPipeline(writer: store))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE ts=100"), 0)
  }
  func testBusyWriterNeverConsumesUnprovenRetryBudget() throws {
    try store.stageCollection(record(0))
    let writer = try ActivityStorage(url: store.url, appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    let pipeline = CollectionPipeline(writer: writer)
    try store.connection.run("BEGIN IMMEDIATE")
    for _ in 0..<10 { pipeline.drain() }
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("ROLLBACK")
    pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=0"))
  }
}
