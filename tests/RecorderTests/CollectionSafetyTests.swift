import Core
import Foundation
import Shell
import XCTest
@testable import Storage

final class CollectionSafetyTests: XCTestCase {
  var folder: URL!
  var store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []))
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  let all = TimeRange(0, 100_000)
  func observation(_ time: Int, observed: Double? = nil, events: [InputObservation] = []) -> ActivityObservation {
    ActivityObservation(sample: TimeSample(ts: time, bundleID: "invented", window: "Invented metadata", documentKey: "invented-key",
      document: "file:///invented/document", inputEvents: events, observedAt: observed,
      windowIdentity: WindowIdentity(processID: 12, windowID: 34), processID: 12, isBrowser: true, isBrowserKnown: true, accessibility: "invented"))
  }
  func capture(_ time: Int) throws -> Int {
    try XCTUnwrap(store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented stable line"), at: time, source: "invented", documentKey: "", project: "", probe: nil).evidenceID)
  }
  func forget(_ range: TimeRange) throws {
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  func testAlreadyStoredCrossSecondEventChangesPreviewAndIsForgottenByOwnTime() throws {
    let range = TimeRange(100, 101), before = try store.previewDeletion(in: range)
    try store.appendObservations([observation(101, events: [InputObservation(kind: .move, timestamp: 100.9, sourcePID: 0), InputObservation(kind: .move, timestamp: 101.1, sourcePID: 0)])])
    let after = try store.previewDeletion(in: range)
    XCTAssertNotEqual(before.confirmation, after.confirmation); XCTAssertEqual(after.counts["input_batches"], 1)
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: before.confirmation))
    try store.deleteRecords(in: range, confirmation: after.confirmation)
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [101.1])
    XCTAssertEqual(try store.observations(in: all).first?.sample.inputEvents.map(\.timestamp), [101.1])
  }
  func testCachedMetadataIsDeletedAndCannotReturnAfterForgetOffOrPause() throws {
    try store.appendObservations([observation(102, observed: 100.9)])
    let range = TimeRange(100, 101)
    XCTAssertEqual(try store.previewDeletion(in: range).counts["sample_observations"], 1)
    try forget(range)
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 200)
    try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 302), at: 201)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 303)
    for timestamp in [100.9, 200.5, 301.5] {
      let value = observation(400 + Int(timestamp), observed: timestamp)
      try store.appendObservations([value]); try store.appendAccountingSamples([value.sample])
    }
    for sample in try store.observations(in: all).map(\.sample) {
      XCTAssertEqual(sample.window, ""); XCTAssertNil(sample.windowIdentity); XCTAssertNil(sample.document)
      XCTAssertNil(sample.processID); XCTAssertNil(sample.isBrowser); XCTAssertNil(sample.accessibility)
    }
    XCTAssertTrue(try store.samples(in: all).allSatisfy { $0.window.isEmpty && $0.documentKey.isEmpty })
  }
  func testInputRetentionUsesEventSecondAndKeepsLaterEvents() throws {
    let now = 30 * 86400 + 101
    try store.appendObservations([observation(102, events: [InputObservation(kind: .move, timestamp: 100.9), InputObservation(kind: .drag, timestamp: 101.1)])])
    _ = try store.cleanRetention(at: now)
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [101.1])
  }
  func testIgnoredPayloadDeleteRollsBackForgetAndRetention() throws {
    let id = try capture(200)
    try store.connection.run("CREATE TRIGGER invented_ignore BEFORE DELETE ON screen_payloads BEGIN SELECT RAISE(IGNORE); END")
    XCTAssertThrowsError(try forget(TimeRange(200, 201)))
    XCTAssertNotNil(try store.screenPayload(evidenceID: id)); XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.deletionsSoFar(), 0)
    XCTAssertThrowsError(try store.cleanRetention(at: 200 + 31 * 86400))
    XCTAssertNotNil(try store.screenPayload(evidenceID: id))
  }
  func testLatePayloadRestorationCannotCommit() throws {
    _ = try capture(200)
    try store.connection.run("CREATE TRIGGER invented_restore AFTER INSERT ON forgotten_ranges BEGIN INSERT INTO screen_payloads(evidence_id,payload) VALUES(1,'{}'); END")
    XCTAssertThrowsError(try forget(TimeRange(200, 201)))
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }
  func testPreviewFreshnessIncludesOnlyStructuredAndObservationContentChanges() throws {
    let id = try capture(200); try store.appendObservations([observation(200)])
    let range = TimeRange(200, 201), a = try store.previewDeletion(in: range)
    try store.connection.run("UPDATE collection_blobs SET content=content||' ' WHERE hash=(SELECT payload_hash FROM screen_payloads WHERE evidence_id=?)", [.integer(id)])
    let b = try store.previewDeletion(in: range); XCTAssertNotEqual(a.confirmation, b.confirmation)
    try store.connection.run("UPDATE sample_observations SET payload=payload||' '")
    XCTAssertNotEqual(b.confirmation, try store.previewDeletion(in: range).confirmation)
  }
  func testRetentionCannotShiftStoredNoveltyOrFormattedSummaryInput() throws {
    for time in [100, 200, 3700, 3800, 7300, 7400] { _ = try capture(time) }
    let range = TimeRange(3700, 7401), before = try store.novelEvidence(in: range)
    let formatted = SummaryFormat().table(range: TimeRange(3600, 7440), samples: [], evidence: before)
    XCTAssertEqual(before.map(\.ts), [3700, 7300])
    _ = try store.cleanRetention(at: 150 + 30 * 86400)
    XCTAssertEqual(try store.novelEvidence(in: range), before)
    XCTAssertEqual(SummaryFormat().table(range: TimeRange(3600, 7440), samples: [], evidence: try store.novelEvidence(in: range)), formatted)
    XCTAssertEqual(try store.recentScreenLineKeys(at: 7400).values.first, 7300)
  }
  func testExcludedAndOwnAppRichFieldsAreClearedIncludingLateExclusionChange() throws {
    try store.saveSettings(StorageSettings(excludedApps: ["invented"]))
    let own = ActivityObservation(sample: TimeSample(ts: 102, bundleID: "dev.local.activityprobe", window: "Invented own", windowIdentity: WindowIdentity(processID: 3, windowID: 4), processID: 3, isBrowser: true, isBrowserKnown: true, accessibility: "invented"))
    try store.appendObservations([observation(101), own])
    for sample in try store.observations(in: all).map(\.sample) {
      XCTAssertTrue(sample.excluded); XCTAssertNil(sample.windowIdentity); XCTAssertNil(sample.processID)
      XCTAssertNil(sample.isBrowser); XCTAssertNil(sample.isBrowserKnown); XCTAssertNil(sample.accessibility)
    }
  }
  func testCompactEncodingPreservesAllFieldsExactlyAndIsSmallerThanJSON() throws {
    let events = (0..<125).map { i in InputObservation(kind: .move, timestamp: 100 + Double(i) / 125,
      sourcePID: i % 3 == 0 ? nil : Int64(i % 3 - 1), button: i % 2, scrollX: Int64.min + Int64(i),
      scrollY: -Int64(i), scrollZ: Int64.max, continuousScroll: i % 2 == 0,
      monotonicNanoseconds: UInt64.max - UInt64(i)) }
    let data = CompactInput.encode(events)
    XCTAssertEqual(try CompactInput.decode(data), events)
    XCTAssertLessThan(data.count, try JSONEncoder().encode(events).count / 2)
    XCTAssertThrowsError(try CompactInput.decode(data.dropLast()))
  }
  func testRangeQueryPlansUseTimeIndexes() throws {
    for sql in ["SELECT id FROM evidence WHERE ts>=100 AND ts<200", "SELECT id FROM input_batches WHERE ts>=100 AND ts<200", "SELECT id FROM sample_observations WHERE observed_ts>=100 AND observed_ts<200", "SELECT evidence_id FROM screen_payloads WHERE metadata_ts>=100 AND metadata_ts<200"] {
      var details = ""
      try store.connection.namedRows("EXPLAIN QUERY PLAN " + sql) { details += try $0.text("detail") }
      XCTAssertTrue(details.contains("SEARCH"), details); XCTAssertFalse(details.contains("SCAN"), details)
    }
  }
  func testDurableObservationPipelineSurvivesSustainedSQLFailureAndRestart() throws {
    var pipeline: CollectionPipeline? = store.makeCollectionPipeline()
    try store.connection.run("BEGIN IMMEDIATE")
    for i in 0..<4000 {
      let events = (0..<125).map { InputObservation(kind: .move, timestamp: Double(100 + i / 2) + Double($0) / 125, sourcePID: 0) }
      // This bulk producer has an explicit flush barrier; ordinary main ticks use
      // the bounded admission deadline covered by the slow-journal regression.
      if i % 128 == 0 { pipeline!.drain() }
      XCTAssertTrue(pipeline!.offer(observation(100 + i / 2, events: events)))
    }
    pipeline!.drain()
    XCTAssertEqual(try store.collectionFiles().count, 4000)
    XCTAssertEqual(try store.observations(in: all).count, 0)
    try store.connection.run("ROLLBACK"); pipeline = nil
    let recovered = store.makeCollectionPipeline()
    for _ in 0..<125 { recovered.drain(); _ = recovered.takeCompletions() }
    XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertEqual(try store.observations(in: all).count, 4000)
    XCTAssertEqual(try store.inputEvents(in: all).count, 500_000)
  }
  func testForgetPreviewIncludesStagedObservationsAndPreventsRetryResurrection() throws {
    let pipeline = store.makeCollectionPipeline()
    try store.connection.run("BEGIN IMMEDIATE"); pipeline.offer(observation(101, observed: 100.9)); pipeline.drain()
    try store.connection.run("ROLLBACK")
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    XCTAssertEqual(preview.counts["staged_collection"], 1)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    pipeline.drain(); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertTrue(try store.observations(in: all).allSatisfy { $0.sample.document == nil && $0.sample.window.isEmpty })
  }

  func testReleaseAndModifierOnlyKeepLegacyRequestsAccountingAndFormattedInput() throws {
    func run(_ kinds: [InputEventKind], label: String) throws -> ([Int], [TimeSample], String, Int) {
      let child = folder.appendingPathComponent(label)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      let db = try ActivityStorage(url: child.appendingPathComponent("invented.sqlite"), appDataDirectory: child, databaseScope: .directory(child))
      try db.saveSettings(StorageSettings(excludedApps: []))
      let clock = FakeClock(), source = FakeSources(); clock.now = 14000; source.clock = clock
      let loop = RecorderLoop(clock: clock, input: source, front: source, secure: source, awake: source, screen: source,
        storage: db, maintenanceStorage: db, ownBundleID: "invented.own")
      source.input = .value(InputCounts(keys: 1)); loop.tick(); loop.flush()
      clock.now += 15; source.screen = .value("Invented second changed screen")
      var counts = InputCounts()
      for kind in kinds { counts.observe(InputObservation(kind: kind, timestamp: Double(clock.now), sourcePID: 0)) }
      source.input = .value(counts); loop.tick(); loop.flush()
      clock.now = 14301; source.input = .value(InputCounts()); loop.tick(); loop.flush(); loop.stop()
      let rows = try db.samples(in: all), evidence = try db.novelEvidence(in: all)
      return (source.requested.map { $0.0 }, rows, SummaryFormat().table(range: TimeRange(13980,14400), samples: rows, evidence: evidence), try db.inputEvents(in: all).count)
    }
    let baseline = try run([], label: "baseline")
    for kind in [InputEventKind.keyUp, .mouseUp, .modifiers] {
      let result = try run([kind], label: kind.rawValue)
      XCTAssertEqual(result.0, baseline.0); XCTAssertEqual(result.1, baseline.1); XCTAssertEqual(result.2, baseline.2)
      XCTAssertEqual(result.3, 1)
    }
    let mixed = try run([.click, .modifiers, .mouseUp], label: "mixed")
    let click = try run([.click], label: "click")
    XCTAssertEqual(mixed.0, click.0); XCTAssertEqual(mixed.1, click.1); XCTAssertEqual(mixed.2, click.2)
  }
  func testKeyRebuildFailureCannotBlockCompleteOccurrenceStorage() throws {
    store.noveltyKeyReader = { _ in throw StorageError("Invented key read failure") }
    _ = try capture(100); _ = try capture(101)
    XCTAssertEqual(try store.evidence(in: all).count, 2)
    XCTAssertEqual(try store.connection.integer("SELECT sum(novelty_rebuild_failed) FROM screen_payloads"), 2)
    XCTAssertThrowsError(try store.novelEvidence(in: all))
    store.noveltyKeyReader = nil
    _ = try capture(102)
    XCTAssertEqual(try store.novelEvidence(in: all).map(\.ts), [100])
  }
  func testUndeployedVersionTenIsRefusedWithoutChangingHistoricalContent() throws {
    for time in [100, 200, 3700, 3800] {
      try store.connection.transaction { try store.insertEvidence(EvidenceText(ts: time, kind: .screen, source: "invented", text: "Invented stable line")) }
      let id = try store.connection.integer("SELECT max(id) FROM evidence")
      try store.connection.run("INSERT INTO screen_payloads(evidence_id,payload) VALUES(?,?)", [.integer(id), .maskedText(String(decoding: JSONEncoder().encode(ScreenTextPayload(text: "Invented stable line")), as: UTF8.self))])
    }
    let before = try store.evidence(in: all)
    try store.connection.run("PRAGMA user_version=10")
    XCTAssertThrowsError(try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder)))
    XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), 10)
    XCTAssertEqual(try store.evidence(in: all), before)
  }
  func testInventedEightHourGrowthMeasurement() throws {
    guard ProcessInfo.processInfo.environment["AP_MEASURE_COLLECTION_GROWTH"] == "1" else { return }
    let baseline = try store.connection.integer("PRAGMA page_count"), start = 1_800_000_000
    func letters(_ number: Int) -> String {
      var n = number; var result = ""
      repeat { result = String(UnicodeScalar(97 + n % 26)!) + result; n /= 26 } while n > 0
      return result
    }
    for scene in 0..<192 {
      let lines = (0..<120).map { "Invented " + letters(scene) + " " + letters($0) + " " + String(repeating: "literal ", count: 6) }
      let payload = ScreenTextPayload(text: lines.joined(separator: "\n"), observations: lines.enumerated().map { index, line in
        OCRObservation(bounds: OCRBounds(x: 0.1, y: Double(index) / 120, width: 0.8, height: 0.008), candidates: [OCRCandidate(text: line, confidence: 0.9), OCRCandidate(text: line + " a", confidence: 0.3), OCRCandidate(text: line + " b", confidence: 0.1)])
      }, languages: ["en-US", "ko-KR"], languageStatus: "supported_automatic", engine: "Vision")
      let masked = payload.redacted()
      for occurrence in 0..<10 { _ = try store.storeScreenCapture(text: masked.text, at: start + (scene * 10 + occurrence) * 15,
        source: "invented.editor", documentKey: "invented", project: "", knownKeys: [], probe: nil, payload: masked, preparedJSON: try screenPayloadJSON(masked), occurrenceID: UUID().uuidString) }
    }
    var batch: [ActivityObservation] = []
    for second in 0..<28800 {
      let events = second < 8640 ? (0..<125).map { InputObservation(kind: .move, timestamp: Double(start + second) + Double($0) / 125,
        sourcePID: 0, monotonicNanoseconds: UInt64(second * 1_000_000_000 + $0 * 8_000_000)) } : []
      batch.append(observation(start + second, observed: Double(start + second), events: events))
      if second % 3 == 0 { batch.append(observation(start + second, observed: Double(start + second))) }
      if batch.count >= 32 { try store.appendObservations(batch); batch.removeAll() }
    }
    try store.appendObservations(batch)
    _ = store.connection.truncateWAL()
    let pages = try store.connection.integer("PRAGMA page_count") - baseline
    let pageSize = try store.connection.integer("PRAGMA page_size")
    print("COLLECTION_GROWTH active_hours=8 captures=1920 scenes=192 observations=38400 events=1080000 move_hz=125 movement_fraction=0.30 added_page_bytes=\(pages * pageSize) \(try store.collectionStatus(at: start + 28800))")
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_blobs"), 384)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches"), 8640)
  }

  func testRepresentativeRecorderTickLatencyWithStructuredPayload() throws {
    final class Screen: ScreenTextSource {
      let payload: ScreenTextPayload
      init(_ value: ScreenTextPayload) { payload = value }
      func captureText(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool, completion: @escaping (SourceReading<String>) -> Void) { completion(.value(payload.text)) }
      func capturePayload(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool, completion: @escaping (SourceReading<ScreenTextPayload>) -> Void) { completion(permitted(.beforeDelivery) ? .value(payload) : .absent(.policyRefused)) }
    }
    let line = "Invented literal content " + String(repeating: "word ", count: 8)
    let payload = ScreenTextPayload(text: Array(repeating: line, count: 120).joined(separator: "\n"), observations: (0..<120).map { _ in
      OCRObservation(bounds: OCRBounds(x: 0, y: 0, width: 1, height: 0.01), candidates: (0..<3).map { _ in OCRCandidate(text: line, confidence: 0.5) })
    })
    let clock = FakeClock(), source = FakeSources(); source.clock = clock
    let screen = Screen(payload)
    let loop = RecorderLoop(clock: clock, input: source, front: source, secure: source, awake: source, screen: screen,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    var times: [Double] = []
    for _ in 0..<30 {
      source.input = .value(InputCounts(keys: 1)); clock.now += 15
      let start = DispatchTime.now().uptimeNanoseconds
      loop.tick()
      times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    loop.flush(); loop.stop(); times.sort()
    print("COLLECTION_TICK_LATENCY samples=30 lines=120 candidates=3 p50_ms=\(times[15]) p95_ms=\(times[28]) max_ms=\(times.last!)")
    XCTAssertEqual(try store.evidence(in: all).count, 30)
    XCTAssertEqual(loop.health.collectionFailures, 0)
  }
  func testStagedNestedForgetPreservesUnrelatedEventsAndScrubsMetadata() throws {
    let pipeline = store.makeCollectionPipeline()
    try store.connection.run("BEGIN IMMEDIATE")
    pipeline.offer(observation(101, observed: 100.9, events: [InputObservation(kind: .move, timestamp: 100.9), InputObservation(kind: .drag, timestamp: 101.1)]))
    pipeline.drain(); try store.connection.run("ROLLBACK")
    try forget(TimeRange(100, 101)); pipeline.drain()
    XCTAssertEqual(try store.inputEvents(in: all).map(\.timestamp), [101.1])
    XCTAssertNil(try store.observations(in: all).first?.sample.document)
  }

  func testDurableCaptureRetryAfterCommitKeepsOneOccurrenceAndStableNovelty() throws {
    let payload = ScreenTextPayload(text: "Invented retry line")
    let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    let record = CollectionRecord(screen: payload, time: 100, source: "invented", screenJSON: json, occurrenceID: "invented-occurrence")
    let pipeline = store.makeCollectionPipeline()
    try store.stageCollection(record); pipeline.drain()
    let before = try store.novelEvidence(in: all)
    try store.stageCollection(record); pipeline.drain()
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertEqual(try store.novelEvidence(in: all), before)
  }

  func cachedCapture(_ time: Int = 102, observed: Double = 100.9) throws -> Int {
    let payload = ScreenTextPayload(text: "Invented later OCR", document: "file:///invented/cached", browserAddress: "https://invented.invalid/cached")
    return try XCTUnwrap(store.storeScreenCapture(text: payload.text, at: time, source: "invented", documentKey: "invented-cached-group", project: "",
      knownKeys: [], probe: nil, payload: payload, metadataObservedAt: observed).evidenceID)
  }
  func testForgetScrubsEarlierOCRMetadataWithoutErasingLaterOCRAndChecksFreshness() throws {
    let id = try cachedCapture(), range = TimeRange(100, 101)
    try store.appendAccountingSamples([TimeSample(ts: 102, window: "Invented cached title", documentKey: "invented-cached-group", keys: 1, observedAt: 100.9)])
    let a = try store.previewDeletion(in: range)
    XCTAssertEqual(a.counts["evidence"], 0); XCTAssertEqual(a.counts["screen_metadata"], 1)
    XCTAssertEqual(a.counts["samples"], 0); XCTAssertEqual(a.counts["sample_metadata"], 1)
    try store.connection.run("UPDATE screen_payloads SET metadata_time='100.8' WHERE evidence_id=?", [.integer(id)])
    let b = try store.previewDeletion(in: range)
    XCTAssertEqual(a.counts, b.counts); XCTAssertNotEqual(a.confirmation, b.confirmation)
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: a.confirmation))
    try store.deleteRecords(in: range, confirmation: b.confirmation)
    let payload = try XCTUnwrap(store.screenPayload(evidenceID: id))
    XCTAssertEqual(payload.text, "Invented later OCR"); XCTAssertNil(payload.document); XCTAssertNil(payload.browserAddress)
    XCTAssertEqual(try store.evidence(in: all).first?.documentKey, "")
    XCTAssertEqual(try store.novelEvidence(in: all).map(\.text), ["Invented later OCR"])
    XCTAssertEqual(try store.previewDeletion(in: range).counts["screen_metadata"], 0)
    let accounting = try XCTUnwrap(store.samples(in: all).first)
    XCTAssertEqual(accounting.ts, 102); XCTAssertEqual(accounting.keys, 1)
    XCTAssertTrue(accounting.window.isEmpty); XCTAssertTrue(accounting.documentKey.isEmpty)
  }
  func testIgnoredOCRMetadataScrubRollsBackForget() throws {
    let id = try cachedCapture()
    try store.connection.run("CREATE TRIGGER invented_ignore_metadata BEFORE UPDATE ON screen_payloads BEGIN SELECT RAISE(IGNORE); END")
    XCTAssertThrowsError(try forget(TimeRange(100, 101)))
    XCTAssertNotNil(try store.screenPayload(evidenceID: id)?.document)
    XCTAssertEqual(try store.deletionsSoFar(), 0)
  }
  func testRetentionScrubsCachedOCRMetadataAndKeepsLaterCapture() throws {
    let id = try cachedCapture()
    _ = try store.cleanRetention(at: 30 * 86400 + 101)
    let payload = try XCTUnwrap(store.screenPayload(evidenceID: id))
    XCTAssertEqual(payload.text, "Invented later OCR"); XCTAssertNil(payload.document); XCTAssertNil(payload.browserAddress)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }
  func testStagedOCRMetadataForgetKeepsLaterOCRAndCannotResurrectOriginals() throws {
    let pipeline = store.makeCollectionPipeline()
    try store.connection.run("BEGIN IMMEDIATE")
    pipeline.offer(payload: ScreenTextPayload(text: "Invented later OCR", document: "file:///invented/cached", browserAddress: "https://invented.invalid/cached"),
      at: 102, source: "invented", documentKey: "invented-cached-group", runID: nil, attemptID: nil, metadataObservedAt: 100.9)
    pipeline.drain(); try store.connection.run("ROLLBACK")
    XCTAssertEqual(try store.previewDeletion(in: TimeRange(100,101)).counts["staged_collection"], 1)
    try forget(TimeRange(100,101)); pipeline.drain()
    let id = try store.connection.integer("SELECT id FROM evidence")
    let payload = try XCTUnwrap(store.screenPayload(evidenceID: id))
    XCTAssertEqual(payload.text, "Invented later OCR"); XCTAssertNil(payload.document); XCTAssertNil(payload.browserAddress)
    XCTAssertEqual(try store.evidence(in: all).first?.documentKey, "")
  }
  func testActualRecorderNeverCarriesHistoricalOffOrPausedMetadataIntoOCR() throws {
    let clock = FakeClock(), sources = FakeSources(); sources.clock = clock
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources, screen: sources,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 500)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 501)
    sources.front.observedAt = 500.5; clock.now = 502; loop.tick(); loop.flush()
    try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 602), at: 600)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 603)
    sources.front.observedAt = 600.5; clock.now = 604; loop.tick(); loop.flush(); loop.stop()
    var ids: [Int] = []
    try store.connection.namedRows("SELECT id FROM evidence") { ids.append(try $0.int("id")) }
    XCTAssertEqual(ids.count, 2)
    for id in ids {
      let payload = try XCTUnwrap(store.screenPayload(evidenceID: id))
      XCTAssertNil(payload.document); XCTAssertNil(payload.browserAddress)
    }
    XCTAssertTrue(try store.evidence(in: all).allSatisfy { $0.documentKey.isEmpty })
  }

  func testIgnoredCaptureChildOrBlobInsertCannotAcknowledgeAcquiredData() throws {
    try store.connection.run("CREATE TRIGGER invented_ignore_child BEFORE INSERT ON screen_payloads BEGIN SELECT RAISE(IGNORE); END")
    let pipeline = store.makeCollectionPipeline()
    pipeline.offer(payload: ScreenTextPayload(text: "Invented held OCR"), at: 100, source: "invented", documentKey: "", runID: nil, attemptID: nil)
    pipeline.drain()
    XCTAssertEqual(try store.evidence(in: all).count, 0); XCTAssertEqual(try store.collectionFiles().count, 1)
    try store.connection.run("DROP TRIGGER invented_ignore_child"); pipeline.drain()
    XCTAssertEqual(try store.evidence(in: all).count, 1); XCTAssertEqual(try store.collectionFiles().count, 0)
    try store.connection.run("CREATE TRIGGER invented_ignore_blob BEFORE INSERT ON collection_blobs BEGIN SELECT RAISE(IGNORE); END")
    XCTAssertThrowsError(try store.appendScreenCapture(text: "Invented different acquired OCR", at: 101, source: "invented", knownKeys: []))
    XCTAssertEqual(try store.evidence(in: all).count, 1)
  }

  func testCrossProcessPayloadFixture() throws {
    guard let root = ProcessInfo.processInfo.environment["AP_COLLECTION_DEDUP_CHILD_ROOT"],
      let time = ProcessInfo.processInfo.environment["AP_COLLECTION_DEDUP_CHILD_TIME"].flatMap(Int.init) else { return }
    let directory = URL(fileURLWithPath: root)
    let shared = try ActivityStorage(url: directory.appendingPathComponent("invented.sqlite"), appDataDirectory: directory, databaseScope: .directory(directory))
    let payload = ScreenTextPayload(text: "Invented stable structured OCR", observations: [OCRObservation(bounds: OCRBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
      candidates: [OCRCandidate(text: "Invented stable structured OCR", confidence: 0.9), OCRCandidate(text: "Invented stable alternate", confidence: 0.1)])],
      languages: ["en-US", "ko-KR"], languageStatus: "automatic", engine: "Vision")
    try shared.appendScreenCapture(payload: payload, at: time, source: "invented", documentKey: "", project: "", probe: nil)
  }
  func testIdenticalStructuredPayloadDeduplicatesAcrossFreshProcesses() throws {
    for time in 100..<105 {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["-XCTest", "RecorderTests.CollectionSafetyTests/testCrossProcessPayloadFixture", Bundle(for: CollectionSafetyTests.self).bundleURL.path]
      var environment = ProcessInfo.processInfo.environment
      environment["AP_COLLECTION_DEDUP_CHILD_ROOT"] = folder.path
      environment["AP_COLLECTION_DEDUP_CHILD_TIME"] = String(time)
      child.environment = environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
    }
    XCTAssertEqual(try store.evidence(in: all).count, 5)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_blobs"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(DISTINCT payload_hash) FROM screen_payloads"), 1)
  }
}
