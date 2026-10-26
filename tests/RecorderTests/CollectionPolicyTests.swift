import Core
import Darwin
import Foundation
import Inbound
import Shell
import XCTest
@testable import Storage

final class CollectionPolicyTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  let all = TimeRange(0, 100_000)
  func observation(_ time: Int = 101, observed: Double? = nil) -> ActivityObservation {
    ActivityObservation(sample: TimeSample(ts: time, bundleID: "invented", window: "Invented metadata", documentKey: "invented-group",
      document: "file:///invented/document", inputEvents: [InputObservation(kind: .move, timestamp: Double(time)-0.1, sourcePID: 0),
        InputObservation(kind: .drag, timestamp: Double(time)+0.1, sourcePID: 0)], observedAt: observed))
  }
  func stageDuringOutage(_ value: ActivityObservation) throws {
    try store.connection.run("BEGIN IMMEDIATE")
    let pipeline = store.makeCollectionPipeline()
    XCTAssertTrue(pipeline.offer(value)); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("ROLLBACK")
  }
  func forget(_ range: TimeRange) throws {
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  func testPartialForgetThenExclusionRefusesEventsOnlyWithCountedReason() throws {
    try stageDuringOutage(observation())
    try forget(TimeRange(101,102))
    XCTAssertEqual(try store.readReadyCollection(XCTUnwrap(store.collectionFiles().first))?.eventsOnly, true)
    try store.saveSettings(StorageSettings(excludedApps: ["INVENTED"]), at: 103)
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertTrue(try store.collectionStatus().contains("collection_refused_input_batch_excluded_app=1"))
  }
  func testExclusionChangedDuringPublicationFailureAndOwnAppCannotWriteRichInput() throws {
    store.collectionPublicationFault = { if $0 == "before-write" { throw StorageError("Invented publication outage") } }
    let pipeline = CollectionPipeline(writer: store)
    XCTAssertTrue(pipeline.offer(observation())); pipeline.drain()
    XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
    try store.saveSettings(StorageSettings(excludedApps: ["invented"]), at: 103)
    store.collectionPublicationFault = nil; pipeline.drain()
    var own = observation(104); own.sample.bundleID = "DEV.LOCAL.ACTIVITYPROBE"
    XCTAssertTrue(pipeline.offer(own)); pipeline.drain()
    XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
    XCTAssertTrue(try store.observations(in: all).allSatisfy { $0.sample.excluded && $0.sample.window.isEmpty })
    let status = try store.collectionStatus()
    XCTAssertTrue(status.contains("input_batch_excluded_app=")); XCTAssertTrue(status.contains("input_batch_own_app="))
  }
  func testLegacyOwnAppEventsOnlyReadyIsExplicitlyRefused() throws {
    try stageDuringOutage(observation())
    let file = try XCTUnwrap(store.collectionFiles().first)
    var record = try XCTUnwrap(store.readReadyCollection(file))
    record.eventsOnly = true; record.observation?.sample.bundleID = "dev.local.activityprobe"
    try JSONEncoder().encode(record).write(to: file)
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty); XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
    XCTAssertTrue(try store.collectionStatus().contains("collection_refused_input_batch_own_app=2"))
  }
  func testHistoricalOffAndPauseKeepEarlierInputAcrossRestartAndIgnoredChildInsert() throws {
    for (index, pause) in [false, true].enumerated() {
      let time = 101 + index*10
      try stageDuringOutage(observation(time))
      try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: pause ? time+1 : nil, recordingEnabled: pause), at: time)
      try store.saveSettings(StorageSettings(excludedApps: []), at: time+1)
      try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON input_batches BEGIN SELECT RAISE(IGNORE); END")
      let pipeline = store.makeCollectionPipeline(); pipeline.drain()
      XCTAssertEqual(try store.collectionFiles().count, 1)
      XCTAssertTrue(try store.inputEvents(in: TimeRange(time-1,time+1)).isEmpty)
      XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
      try store.connection.run("DROP TRIGGER invented_ignore")
      let restarted = store.makeCollectionPipeline(); restarted.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(try store.inputEvents(in: TimeRange(time-1,time)).count, 1)
      XCTAssertTrue(try store.inputEvents(in: TimeRange(time,time+1)).isEmpty)
      XCTAssertTrue(try store.observations(in: all).isEmpty)
      XCTAssertTrue(try store.collectionStatus().contains("container_historical_off_or_pause="))
    }
  }
  func testCurrentOffAndCurrentPauseRefuseEveryComponent() throws {
    for pause in [false, true] {
      try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
      try stageDuringOutage(observation())
      try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: pause ? Int(Date().timeIntervalSince1970)+3600 : nil, recordingEnabled: pause), at: 103)
      let pipeline = store.makeCollectionPipeline(); pipeline.drain()
      XCTAssertTrue(try store.collectionFiles().isEmpty); XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
      XCTAssertTrue(try store.observations(in: all).isEmpty)
    }
  }
  func testUnpublishedObservationCaptureAndIndependentClocksHonorRetentionWatermark() throws {
    store.collectionPublicationFault = { if $0 == "policy-read" { throw StorageError("Invented policy outage") } }
    let pipeline = CollectionPipeline(writer: store)
    var old = observation(100, observed: 102.2)
    old.sample.keepingAwake = true
    old.sample.inputEvents = [InputObservation(kind: .move, timestamp: 100.9), InputObservation(kind: .drag, timestamp: 102.1)]
    XCTAssertTrue(pipeline.offer(old))
    XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented expired OCR", document: "file:///invented/later"), at: 100,
      source: "invented", documentKey: "invented", runID: nil, attemptID: nil, metadataObservedAt: 102.4))
    var later = observation(102, observed: 100.8); later.sample.inputEvents = old.sample.inputEvents
    XCTAssertTrue(pipeline.offer(later))
    XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented retained OCR", document: "file:///invented/expired"), at: 102,
      source: "invented", documentKey: "invented", runID: nil, attemptID: nil, metadataObservedAt: 100.7))
    pipeline.drain(); XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
    _ = try store.cleanRetention(at: 30*86400+101)
    store.collectionPublicationFault = nil; pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).map(\.sample.ts), [102])
    XCTAssertNil(try store.observations(in: all).first?.sample.observedAt)
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [102.1,102.1])
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [102])
    XCTAssertNil(try store.screenPayload(evidenceID: store.connection.integer("SELECT id FROM evidence"))?.document)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE ts=102"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE COALESCE(json_extract(payload,'$.sample.keepingAwake'),0)!=0"), 0)
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
    XCTAssertTrue(try store.collectionStatus().contains("retention="))
    let before = try store.previewDeletion(in: TimeRange(102,103))
    XCTAssertEqual(before.counts["collection_metadata"], 2)
    try store.connection.run("UPDATE collection_metadata SET payload=payload||' '")
    XCTAssertThrowsError(try store.deleteRecords(in: before.range, confirmation: before.confirmation))
    try forget(TimeRange(102,103))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
  }
  func testReadOnlyDirectoryAndPostPublicationMemoryCannotResurrectExpiredComponents() throws {
    for point in ["directory", "after-sync"] {
      let time = point == "directory" ? 100 : 86_500
      let pipeline = CollectionPipeline(writer: store)
      if point == "directory" {
        try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.collectionDirectory.path)
      } else { store.collectionPublicationFault = { if $0 == point { throw StorageError("Invented interrupted acknowledgement") } } }
      XCTAssertTrue(pipeline.offer(observation(time)))
      XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented expired capture"), at: time, source: "invented", documentKey: "", runID: nil, attemptID: nil))
      pipeline.drain(); XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
      // An unwritable directory may prevent erasure, but the committed cutoff still
      // prevents retry. Restore only for cleanup, never to publish before retention.
      if point == "directory" { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.collectionDirectory.path) }
      _ = try store.cleanRetention(at: (point == "directory" ? 31 : 32)*86400)
      store.collectionPublicationFault = nil; pipeline.drain()
      XCTAssertTrue(try store.observations(in: all).isEmpty); XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
      XCTAssertTrue(try store.evidence(in: all).isEmpty); XCTAssertTrue(try store.collectionFiles().isEmpty)
      XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
    }
  }
  func testRetentionShorteningDuringOutageAndLaterLengtheningCannotResurrect() throws {
    store.collectionPublicationFault = { if $0 == "policy-read" { throw StorageError("Invented outage") } }
    let pipeline = CollectionPipeline(writer: store)
    XCTAssertTrue(pipeline.offer(observation(10*86400))); pipeline.drain()
    _ = try store.cleanRetention(at: 31*86400)
    var settings = StorageSettings(excludedApps: []); settings.screenRetentionDays = 7
    try store.saveSettings(settings, at: 31*86400); _ = try store.cleanRetention(at: 31*86400)
    settings.screenRetentionDays = 30; try store.saveSettings(settings, at: 31*86400)
    store.collectionPublicationFault = nil; pipeline.drain()
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches"), 0)
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }
  func testIndependentMetadataWriteAndRefusalProofAreRequiredForAcknowledgement() throws {
    try stageDuringOutage(observation(observed: 100.5))
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 101)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 102)
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON collection_metadata BEGIN SELECT RAISE(IGNORE); END")
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1); XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
    try store.connection.run("DROP TRIGGER invented_ignore")
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON collection_policy_refusals BEGIN SELECT RAISE(IGNORE); END")
    pipeline.drain(); XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_ignore"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 1)
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [100.9])
    _ = try store.cleanRetention(at: 31*86400)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
  }
  func testAcknowledgedCommitReplayAfterExclusionDoesNotRewriteOrBlockAllowedHistory() throws {
    let value = observation(observed: 100.5)
    try store.appendObservations([value])
    try store.stageCollection(CollectionRecord(observation: value, time: 101, observationEvents: CompactInput.encode(value.sample.inputEvents)))
    try store.saveSettings(StorageSettings(excludedApps: ["invented"]), at: 103)
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.inputEvents(in: all).count, 2)
    XCTAssertEqual(try store.observations(in: all).count, 1)
    XCTAssertTrue(try store.collectionStatus().contains("input_batch_excluded_app=2"))
  }
  func testIgnoredScreenParentAndMismatchedCaptureReplayCannotConsumeReady() throws {
    let record = CollectionRecord(screen: ScreenTextPayload(text: "Invented capture"), time: 101, source: "invented", occurrenceID: "invented-occurrence")
    try store.stageCollection(record)
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON evidence BEGIN SELECT RAISE(IGNORE); END")
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_ignore"); pipeline.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    try store.stageCollection(record)
    try store.connection.run("UPDATE collection_blobs SET content='Invented changed capture' WHERE hash=(SELECT text_hash FROM screen_payloads)")
    pipeline.drain(); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertTrue(try store.collectionStatus().contains("collection_unrecoverable_total=1"))
    XCTAssertGreaterThan(pipeline.takeDiagnostics().persistenceFailures, 0)
  }
  func testUndeployedVersionTwelveIsRefusedWithoutRewritingHistoricalContent() throws {
    let value = observation(observed: 100.5)
    try store.appendObservations([value])
    let before = try store.observations(in: all)
    try store.connection.run("PRAGMA user_version=12")
    XCTAssertThrowsError(try ActivityStorage(url: store.url, appDataDirectory: folder, databaseScope: .directory(folder)))
    XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), 12)
    XCTAssertEqual(try store.observations(in: all), before)
  }
  func testStoredParentForgetPreservesLaterMetadataAndMetadataForgetPreservesParent() throws {
    try checkStoredComponentErasure(retention: false)
  }
  func testStoredParentRetentionPreservesLaterMetadataAndMetadataRetentionPreservesParent() throws {
    try checkStoredComponentErasure(retention: true)
  }
  func checkStoredComponentErasure(retention: Bool) throws {
    try store.appendObservations([observation(100, observed: 102.5), observation(103, observed: 100.5)])
    for (parent, metadata) in [(100,102.5),(103,100.5)] {
      try store.storeScreenCapture(text: "Invented OCR", at: parent, source: "invented", documentKey: "invented", project: "", knownKeys: [], probe: nil,
        payload: ScreenTextPayload(text: "Invented OCR", document: "file:///invented/document"), metadataObservedAt: metadata)
    }
    // Migrated payloads retain the independently derived second without an exact-time string.
    try store.connection.run("UPDATE screen_payloads SET metadata_time=NULL")
    if retention { _ = try store.cleanRetention(at: 30*86400+101) }
    else { try forget(TimeRange(100,101)) }
    let remaining = try store.observations(in: all)
    XCTAssertEqual(remaining.map(\.sample.ts), [103]); XCTAssertNil(remaining.first?.sample.observedAt)
    XCTAssertEqual(remaining.first?.sample.window, "")
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE ts=102"), 2)
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [103])
    XCTAssertNil(try store.screenPayload(evidenceID: store.connection.integer("SELECT id FROM evidence"))?.document)
    XCTAssertEqual(try store.inputEvents(in: TimeRange(102,104)).count, 2)
  }
  func testReadyRetentionPreservesIndependentComponentsAcrossRestart() throws {
    var value = observation(100, observed: 102.5)
    value.sample.keys = 7; value.sample.clicks = 6; value.sample.scrolls = 5
    value.sample.moved = true; value.sample.synthetic = 3; value.sample.keepingAwake = true
    value.sample.inputEvents.append(InputObservation(kind: .move, timestamp: 102.1))
    try stageDuringOutage(value)
    try store.connection.run("BEGIN IMMEDIATE")
    let blocked = store.makeCollectionPipeline()
    XCTAssertTrue(blocked.offer(payload: ScreenTextPayload(text: "Invented expired capture", document: "file:///invented/later"), at: 100,
      source: "invented", documentKey: "invented", runID: nil, attemptID: nil, metadataObservedAt: 102.4))
    blocked.drain(); try store.connection.run("ROLLBACK")
    _ = try store.cleanRetention(at: 30*86400+101)
    for file in try store.collectionFiles() {
      if let sample = try store.readReadyCollection(file)?.observation?.sample {
        XCTAssertEqual(sample.keys+sample.clicks+sample.scrolls+sample.synthetic, 0)
        XCTAssertFalse(sample.moved); XCTAssertFalse(sample.keepingAwake)
      }
    }
    let restarted = store.makeCollectionPipeline(); restarted.drain()
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [102.1])
    XCTAssertTrue(try store.observations(in: all).isEmpty); XCTAssertTrue(try store.evidence(in: all).isEmpty)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata"), 2)
  }
  func testIgnoredRetentionWatermarkRollsBackCleanupAndDoesNotDiscardPendingWork() throws {
    store.collectionPublicationFault = { if $0 == "policy-read" { throw StorageError("Invented publication outage") } }
    let pipeline = CollectionPipeline(writer: store)
    XCTAssertTrue(pipeline.offer(observation())); pipeline.drain()
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE INSERT ON collection_retention BEGIN SELECT RAISE(IGNORE); END")
    XCTAssertThrowsError(try store.cleanRetention(at: 31*86400))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_retention"), 0)
    try store.connection.run("DROP TRIGGER invented_ignore")
    store.collectionPublicationFault = nil; pipeline.drain()
    XCTAssertEqual(try store.observations(in: all).count, 1)
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }
  func testAcquisitionExcludedInputIsCountedByTheSharedPolicyBeforeBlanking() throws {
    var value = observation(observed: 100.5); value.sample.excluded = true
    let pipeline = store.makeCollectionPipeline()
    XCTAssertTrue(pipeline.offer(value)); pipeline.drain()
    XCTAssertTrue(try store.inputEvents(in: all).isEmpty)
    let stored = try XCTUnwrap(store.observations(in: all).first)
    XCTAssertTrue(stored.sample.excluded); XCTAssertTrue(stored.sample.window.isEmpty)
    XCTAssertNil(stored.sample.observedAt)
    let status = try store.collectionStatus()
    XCTAssertTrue(status.contains("collection_refused_input_batch_excluded_at_acquisition=2"))
    XCTAssertTrue(status.contains("collection_refused_metadata_excluded_at_acquisition=1"))
  }
  func testInlineReadyInputUsesItsOwnTimeForPreviewFreshnessForgetAndRecovery() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    let file = store.collectionDirectory.appendingPathComponent("invented-inline.json")
    var record = CollectionRecord(observation: observation(), time: 101)
    try JSONEncoder().encode(record).write(to: file)
    let before = try store.previewDeletion(in: TimeRange(100,101))
    XCTAssertEqual(before.counts["staged_collection"], 1)
    record.observation?.sample.inputEvents[0].timestamp = 100.8
    try JSONEncoder().encode(record).write(to: file)
    XCTAssertThrowsError(try store.deleteRecords(in: before.range, confirmation: before.confirmation))
    try forget(TimeRange(100,101))
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [101.1])
    XCTAssertTrue(try store.collectionFiles().isEmpty)
  }
  func testNativeAccumulationHasExplicitEventCountBoundAndPreservesAccounting() throws {
    var counts = InputCounts()
    for i in 0..<(MacInputSource.maximumEventsBetweenDrains+1000) {
      counts.observe(InputObservation(kind: .key, timestamp: 100+Double(i)/1_000_000, sourcePID: 0), retainingAtMost: MacInputSource.maximumEventsBetweenDrains)
    }
    XCTAssertEqual(counts.events.count, 65_536); XCTAssertEqual(counts.detailedEventOverflow, 1000)
    XCTAssertEqual(counts.keys, 66_536); XCTAssertTrue(counts.byPerson)
    let clock = FakeClock(), source = FakeSources(); clock.now = 100; source.clock = clock
    source.input = .value(counts)
    let loop = RecorderLoop(clock: clock, input: source, front: source, secure: source, awake: source, screen: source,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    loop.tick(); loop.stop(); XCTAssertEqual(loop.health.nativeEventLimitRefusals, 1000)
  }
  func testPrivacyTraversalMeasurements51220488192Records() throws {
    try FileManager.default.createDirectory(at: store.collectionDirectory, withIntermediateDirectories: true)
    let encoded = try JSONEncoder().encode(CollectionRecord(observation: observation(), time: 101))
    var previous = 0
    for count in [512,2048,8192] {
      for i in previous..<count { try encoded.write(to: store.collectionDirectory.appendingPathComponent(String(format: "r-%020d.json", i))) }
      let scans = store.collectionEnumerationVisits
      let start = DispatchTime.now().uptimeNanoseconds
      let preview = try store.previewDeletion(in: TimeRange(100,103))
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
      XCTAssertEqual(preview.counts["staged_collection"], count)
      XCTAssertEqual(store.collectionEnumerationVisits-scans, count)
      XCTAssertEqual(preview.confirmation, try store.previewDeletion(in: preview.range).confirmation)
      print("COLLECTION_CURSOR records=\(count) preview_ms=\(elapsed) encoded_peak_bytes=\(store.collectionPeakReadBytes)")
      previous = count
    }
    try forget(TimeRange(100,103)); XCTAssertTrue(try store.collectionFiles().isEmpty)
  }
  func testReceivedEventAndLargeCaptureFixtureMeasuresActualPipeline() throws {
    var before = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
    let events = (0..<65_536).map { InputObservation(kind: .scroll, timestamp: 100+Double($0)/100_000,
      sourcePID: Int64($0), button: $0%8, scrollX: Int64.min+Int64($0), scrollY: -Int64($0), scrollZ: Int64.max,
      continuousScroll: true, monotonicNanoseconds: UInt64.max-UInt64($0)) }
    var value = observation(101); value.sample.inputEvents = events
    let line = String(repeating: "Invented capture words ", count: 256)
    let candidates = (0..<10).map { OCRCandidate(text: line+String($0), confidence: Float($0)/10) }
    let observations = (0..<120).map { _ in OCRObservation(bounds: OCRBounds(x: 0.1,y: 0.1,width: 0.5,height: 0.01), candidates: candidates) }
    let payload = ScreenTextPayload(text: String(repeating: "Invented OCR text\n", count: 65_536), observations: observations)
    let pipeline = store.makeCollectionPipeline(), start = DispatchTime.now().uptimeNanoseconds
    XCTAssertTrue(pipeline.offer(value))
    let eventOfferMS = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
    pipeline.drain()
    let eventMS = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
    let captureStart = DispatchTime.now().uptimeNanoseconds
    XCTAssertGreaterThan(payload.estimatedBytes*4, CollectionPipeline.queueBytes+CollectionPipeline.overflowBytes)
    XCTAssertTrue(pipeline.offer(payload: payload, at: 102, source: "invented", documentKey: "", runID: nil, attemptID: nil))
    let captureOfferMS = Double(DispatchTime.now().uptimeNanoseconds-captureStart)/1_000_000
    pipeline.drain()
    let captureMS = Double(DispatchTime.now().uptimeNanoseconds-captureStart)/1_000_000
    XCTAssertEqual(try store.inputEvents(in: all), events)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    var after = rusage(); XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
    print("COLLECTION_RECEIVED input_offer_ms=\(eventOfferMS) capture_offer_ms=\(captureOfferMS) process_peak_rss_before_bytes=\(before.ru_maxrss) process_peak_rss_after_bytes=\(after.ru_maxrss) events=65536 encoded_input_bytes=\(CompactInput.encode(events).count) event_pipeline_ms=\(eventMS) capture_estimated_bytes=\(payload.estimatedBytes) capture_pipeline_ms=\(captureMS) candidates=1200")
    XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
  }
}
