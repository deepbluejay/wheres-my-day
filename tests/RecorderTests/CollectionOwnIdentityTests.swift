import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionOwnIdentityTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  let own = "invented.custom-own"
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try reopen(own: "invented.previous-own")
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  func reopen(own: String) throws {
    store = nil
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder), ownBundleID: own)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func observation(ownApp: Bool) -> ActivityObservation {
    let second = ownApp ? 100 : 101
    return ActivityObservation(id: ownApp ? "invented-own" : "invented-other", sample: TimeSample(ts: second,
      bundleID: ownApp ? own.uppercased() : "invented.other", window: "Invented context", documentKey: "invented-group",
      document: "file:///invented/document", browserAddress: "https://invented.invalid/embedded",
      inputEvents: [InputObservation(kind: .move, timestamp: Double(second)+0.5)], observedAt: Double(second)+0.5))
  }
  func assertOnlyControlContext() throws {
    let observations = try store.observations(in: TimeRange(0,1000))
    XCTAssertEqual(observations.count, 2)
    let hidden = try XCTUnwrap(observations.first { $0.id == "invented-own" }).sample
    XCTAssertTrue(hidden.excluded); XCTAssertEqual(hidden.window, ""); XCTAssertEqual(hidden.documentKey, "")
    XCTAssertNil(hidden.document); XCTAssertNil(hidden.browserAddress); XCTAssertNil(hidden.observedAt)
    XCTAssertTrue(hidden.inputEvents.isEmpty)
    let control = try XCTUnwrap(observations.first { $0.id == "invented-other" }).sample
    XCTAssertFalse(control.excluded); XCTAssertEqual(control.window, "Invented context")
    XCTAssertEqual(control.browserAddress, "https://invented.invalid/embedded")
    XCTAssertEqual(control.inputEvents.count, 1)
    XCTAssertEqual(try store.inputEvents(in: TimeRange(0,1000)).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
  }
  func testCustomOwnIdentitySurvivesReadyReplayAndDefaultWriterReopen() throws {
    for ownApp in [true, false] {
      let value = observation(ownApp: ownApp)
      try store.stageCollection(CollectionRecord(observation: value, time: value.sample.ts))
      try store.stageCollection(CollectionRecord(screen: ScreenTextPayload(text: "Invented OCR", document: "invented-document"),
        time: value.sample.ts, source: value.sample.bundleID, documentKey: "invented-group",
        occurrenceID: ownApp ? "invented-own-screen" : "invented-other-screen", metadataObservedAt: Double(value.sample.ts)+0.5))
    }
    XCTAssertEqual(try store.collectionFiles().count, 4)
    try reopen(own: own)
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    try assertOnlyControlContext()
    XCTAssertEqual(try store.evidence(in: TimeRange(0,1000)).map(\.source), ["invented.other"])
    XCTAssertGreaterThan(try store.connection.integer("SELECT COALESCE(sum(count),0) FROM collection_policy_refusals WHERE reason LIKE '%own_app'"), 0)
    try reopen(own: own.uppercased())
    try store.stageCollection(CollectionRecord(observation: observation(ownApp: true), time: 100))
    let replay = store.makeCollectionPipeline(); replay.drain()
    XCTAssertEqual(replay.takeDiagnostics().persistenceFailures, 0)
    try assertOnlyControlContext()
  }
  func testInjectedPipelineIdentityAppliesBeforeDelayedPublicationAndPersistence() throws {
    try store.connection.run("BEGIN IMMEDIATE")
    let pipeline = store.makeCollectionPipeline(ownBundleID: own)
    XCTAssertTrue(pipeline.offer(observation(ownApp: true)))
    XCTAssertTrue(pipeline.offer(observation(ownApp: false)))
    pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 2)
    for file in try store.collectionFiles() {
      let value = try XCTUnwrap(store.readReadyCollection(file)?.observation)
      if value.id == "invented-own" {
        XCTAssertTrue(value.sample.excluded); XCTAssertEqual(value.sample.window, "")
        XCTAssertNil(value.sample.document); XCTAssertNil(value.sample.browserAddress)
      }
    }
    try store.connection.run("ROLLBACK")
    pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    try assertOnlyControlContext()
  }
}
