import Core
import Foundation
import SQLite3
import XCTest
@testable import Storage

final class CollectionConcurrencyTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  private func open(_ folder: URL, busy: Int32 = 3000) throws -> ActivityStorage {
    try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      busyMilliseconds: busy, databaseScope: .directory(folder))
  }
  private func fixture() throws -> (URL, ActivityStorage) {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try open(folder)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
    return (folder, store)
  }
  private func observations(_ range: Range<Int>, metadata: Double) -> [ActivityObservation] {
    range.map { ActivityObservation(id: "invented-\($0)", sample: TimeSample(ts: 100 + $0 / 2,
      bundleID: "invented", window: "Invented", documentKey: "invented", observedAt: metadata)) }
  }
  private func assertGap(_ store: ActivityStorage, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(sqlite3_get_autocommit(store.connection.handle), 1, file: file, line: line)
    XCTAssertEqual(sqlite3_txn_state(store.connection.handle, "main"), SQLITE_TXN_NONE, file: file, line: line)
    XCTAssertNil(sqlite3_next_stmt(store.connection.handle, nil), file: file, line: line)
  }

  func testIndependentMetadataPreservationWithActualPipelineBothCompletionOrdersAndReopen() throws {
    for screen in [false, true] { for retention in [false, true] { for pipelineFirst in [false, true] {
      let (folder, store) = try fixture(), writer = try open(folder, busy: 0)
      if screen {
        for index in 0..<300 {
          _ = try store.storeScreenCapture(text: "Invented", at: 100 + index / 2, source: "invented",
            documentKey: "invented", project: "", knownKeys: [], probe: nil,
            payload: ScreenTextPayload(text: "Invented", document: "invented"),
            occurrenceID: "invented-\(index)", metadataObservedAt: 500.5)
        }
      } else { try store.appendObservations(observations(0..<300, metadata: 500.5)) }
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      // The second order holds preparation before it acquires any production lock.
      let pipeline = CollectionPipeline(database: store.url) {
        entered.signal()
        if !pipelineFirst { XCTAssertEqual(release.wait(timeout: .now() + 10), .success) }
        return writer
      }
      let preview = try store.previewDeletion(in: TimeRange(100,400))
      var offered = false
      store.connection.collectionMaintenanceGap = {
        self.assertGap(store)
        guard !offered else { return }
        offered = true
        let preserved = try store.connection.integer("SELECT count(*) FROM collection_metadata")
        XCTAssertGreaterThan(preserved, 0); XCTAssertLessThan(preserved, 300)
        XCTAssertTrue(pipeline.offer(ActivityObservation(id: "invented-allowed", sample: TimeSample(ts: 600, bundleID: "invented"))))
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        if pipelineFirst {
          pipeline.drain()
          XCTAssertEqual(try writer.connection.integer("SELECT count(*) FROM sample_observations WHERE observation_id='invented-allowed'"), 1)
          XCTAssertGreaterThan(try writer.connection.integer("SELECT count(*) FROM \(screen ? "evidence" : "sample_observations") WHERE ts<400"), 0)
        }
      }
      defer { store.connection.collectionMaintenanceGap = nil }
      if retention { _ = try store.cleanRetention(at: 30 * 86400 + 400) }
      else { try store.deleteRecords(in: preview.range, confirmation: preview.confirmation) }
      XCTAssertTrue(offered)
      if !pipelineFirst {
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations WHERE observation_id='invented-allowed'"), 0)
        release.signal()
      }
      pipeline.drain()
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      XCTAssertEqual(pipeline.takeCompletions().0.reduce(0) { $0 + $1.storedObservations }, 1)
      let reopened = try open(folder)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM collection_metadata WHERE ts=500"), 300)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM evidence WHERE ts<400"), 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations WHERE ts<400"), 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations"), 1)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM collection_policy_refusals WHERE reason=? AND count=300", [.key((screen ? "capture_" : "container_") + (retention ? "retention" : "forgotten"))]), 1)
      XCTAssertTrue(try reopened.collectionFiles().isEmpty)
      XCTAssertEqual(try reopened.appendObservations([ActivityObservation(id: "invented-refused", sample: TimeSample(ts: 100, bundleID: "invented"))]).stored, 0)
    } } }
  }

  private enum Competitor: CaseIterable { case forget, retention, insert, complete, recover, preview }
  private func call(_ id: String, pending: Bool = false) -> ModelCall {
    ModelCall(ts: 2000, range: TimeRange(2000,2060), model: "invented", inputTokens: 22,
      cachedTokens: 3, outputTokens: 7, succeeded: !pending,
      tableFacts: SummaryCallFacts(through: 2060, sentRanges: [TimeRange(2000,2060)], endsAtRest: false, activeMinutes: [2000]),
      pending: pending, attemptID: id)
  }
  func testPrivacyPlansSerializeCompetingOperationsInBothOrdersWithSequentialControlsAndReopen() throws {
    for kind in Competitor.allCases { for reverse in [false, true] { for concurrent in [false, true] {
      let (folder, store) = try fixture(), other = try open(folder)
      try store.appendObservations(observations(0..<300, metadata: 500.5))
      try store.appendObservations((0..<300).map { ActivityObservation(id: "invented-later-\($0)",
        sample: TimeSample(ts: 900 + $0 / 5, bundleID: "invented", observedAt: 1200.5)) })
      let original = ModelCall(ts: 1000, range: TimeRange(60,1020), model: "invented", inputTokens: 41,
        cachedTokens: 5, outputTokens: 13, succeeded: true,
        tableFacts: SummaryCallFacts(through: 1020, sentRanges: [TimeRange(60,1020)], endsAtRest: false, activeMinutes: [120,900]))
      try store.appendModelCall(original)
      if kind == .complete { try store.appendModelCall(call("invented-pending", pending: true)) }
      if kind == .recover { try ModelCallJournal(database: store.url).save(call("invented-recovered")) }
      let forgetRange = kind == .retention ? TimeRange(900,960) : TimeRange(100,400)
      let preview = try store.previewDeletion(in: forgetRange)
      let later = try other.previewDeletion(in: TimeRange(900,960))
      let forget: () throws -> Void = { try store.deleteRecords(in: forgetRange, confirmation: preview.confirmation) }
      let compete: () throws -> Void = {
        switch kind {
        case .forget: try other.deleteRecords(in: later.range, confirmation: later.confirmation)
        case .retention: _ = try other.cleanRetention(at: 30 * 86400 + 400)
        case .insert: XCTAssertEqual(try other.appendModelCall(self.call("invented-new")).stored, 1)
        case .complete: XCTAssertEqual(try other.appendModelCall(self.call("invented-pending")).stored, 1)
        case .recover: try other.recoverModelCalls()
        case .preview: XCTAssertEqual(try other.previewDeletion(in: later.range).confirmation, later.confirmation)
        }
      }
      let first = reverse ? compete : forget, second = reverse ? forget : compete
      if concurrent {
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let firstStore = reverse ? other : store
        let secondDone = expectation(description: "Competing operation completes")
        var launched = false
        let launch: () throws -> Void = {
          guard !launched else { return }; launched = true
          DispatchQueue.global().async {
            started.signal()
            do { try second() } catch { XCTFail("kind=\(kind) reverse=\(reverse): \(error)") }
            finished.signal(); secondDone.fulfill()
          }
          XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
          XCTAssertEqual(finished.wait(timeout: .now() + 0.03), .timedOut)
        }
        if reverse && [.insert, .complete, .recover].contains(kind) {
          firstStore.connection.collectionCommitClock = { do { try launch() } catch { XCTFail("\(error)") }; return 200_000 }
        } else if reverse && kind == .preview {
          // A read-only preview has no write/checkpoint seam; keep its ordinary
          // concurrent read control and verify the resulting approval below.
          DispatchQueue.global().async { do { try second() } catch { XCTFail("\(error)") }; secondDone.fulfill() }
        } else {
          firstStore.connection.collectionMaintenanceGap = {
            self.assertGap(firstStore)
            try launch()
          }
        }
        try first()
        firstStore.connection.collectionMaintenanceGap = nil
        wait(for: [secondDone], timeout: 10)
        if kind != .preview || !reverse { XCTAssertTrue(launched) }
      } else { try first(); try second() }
      let reopened = try open(folder)
      let saved = try reopened.modelCalls(in: TimeRange(0,4000))
      let retained = try XCTUnwrap(saved.first { $0.inputTokens == 41 })
      var billing = retained; billing.tableFacts = nil
      var expectedBilling = original; expectedBilling.tableFacts = nil
      XCTAssertEqual(billing, expectedBilling)
      let both = kind == .forget || kind == .retention
      let erased = both ? [TimeRange(100,400),TimeRange(900,960)] : [forgetRange]
      for range in erased {
        if kind != .retention || range == forgetRange {
          XCTAssertFalse(retained.tableFacts!.sentRanges.contains { $0.start < range.end && $0.end > range.start })
          XCTAssertFalse(retained.tableFacts!.activeMinutes.contains { $0 < range.end && $0 + 60 > range.start })
        }
        XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations WHERE ts>=? AND ts<?", [.integer(range.start), .integer(range.end)]), 0)
        XCTAssertEqual(try reopened.appendObservations([ActivityObservation(id: UUID().uuidString,
          sample: TimeSample(ts: range.start, bundleID: "invented"))]).stored, 0)
      }
      if kind == .insert || kind == .complete || kind == .recover {
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.last?.inputTokens, 22); XCTAssertEqual(saved.last?.cachedTokens, 3)
        XCTAssertEqual(saved.last?.outputTokens, 7); XCTAssertEqual(saved.last?.pending, false)
        XCTAssertEqual(saved.last?.succeeded, true)
        XCTAssertEqual(saved.last?.tableFacts, call("invented").tableFacts)
      }
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM forgotten_ranges"), kind == .forget ? 2 : 1)
      let overlapping = ModelCall(ts: 2001, range: forgetRange, model: "invented", inputTokens: 1,
        succeeded: true, attemptID: "invented-refused")
      XCTAssertEqual(try reopened.appendModelCall(overlapping).refused, 1)
    } } }
  }

  func testReviewGuardIsRecheckedAfterEveryYieldAndRetryKeepsProgress() throws {
    for retention in [false, true] {
      let (folder, store) = try fixture(), other = try open(folder)
      try store.appendObservations(observations(0..<300, metadata: 500.5))
      let preview = try store.previewDeletion(in: TimeRange(100,400))
      var changed = false
      store.connection.collectionMaintenanceGap = {
        guard !changed else { return }; changed = true
        let continuous = AXProbeReviewLease.continuous(), wall = Date().timeIntervalSince1970
        let lease: [String: Any] = ["boot": AXProbeReviewLease.bootID(), "sessionStart": continuous, "issued": continuous,
          "deadline": continuous + 10, "issuedWall": wall, "deadlineWall": wall + 10]
        try other.connection.transaction {
          try other.connection.run("INSERT INTO settings(key,value) VALUES('general.axProbe.reviewActive','1')")
          try other.connection.run("INSERT INTO settings(key,value) VALUES('general.axProbe.reviewLease',?)",
            [.key(String(decoding: try JSONSerialization.data(withJSONObject: lease), as: UTF8.self))])
        }
      }
      XCTAssertThrowsError(try {
        if retention { _ = try store.cleanRetention(at: 30 * 86400 + 400) }
        else { try store.deleteRecords(in: preview.range, confirmation: preview.confirmation) }
      }()) { XCTAssertTrue(String(describing: $0).contains("Close the probe review")) }
      XCTAssertTrue(changed)
      store.connection.collectionMaintenanceGap = nil
      let reopened = try open(folder)
      XCTAssertGreaterThan(try reopened.connection.integer("SELECT count(*) FROM sample_observations"), 0)
      XCTAssertGreaterThan(try reopened.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
      XCTAssertEqual(try reopened.connection.integer(retention ? "SELECT count(*) FROM collection_retention WHERE screen_cutoff=400" : "SELECT count(*) FROM forgotten_ranges WHERE start_ts=100 AND end_ts=400"), 1)
      try reopened.connection.run("DELETE FROM settings WHERE key IN ('general.axProbe.reviewActive','general.axProbe.reviewLease')")
      if retention { _ = try reopened.cleanRetention(at: 30 * 86400 + 400) }
      else {
        let fresh = try reopened.previewDeletion(in: preview.range)
        try reopened.deleteRecords(in: fresh.range, confirmation: fresh.confirmation)
      }
      let final = try open(folder)
      XCTAssertEqual(try final.connection.integer("SELECT count(*) FROM sample_observations"), 0)
      XCTAssertEqual(try final.connection.integer("SELECT count(*) FROM collection_metadata"), 300)
    }
  }

  func testPromptRetentionPolicyIsFreshAfterYieldInBothDirectionsAndReopen() throws {
    for lengthen in [false, true] {
      let (folder, store) = try fixture(), other = try open(folder)
      var settings = try store.settings()
      settings.promptRetentionDays = lengthen ? 1 : 30
      try store.saveSettings(settings, at: 0)
      try store.appendObservations(observations(0..<300, metadata: 500.5))
      try store.appendEvidence([EvidenceText(ts: 500, kind: .prompt, source: "invented", text: "Invented")])
      var changed = false
      store.connection.collectionMaintenanceGap = {
        guard !changed else { return }; changed = true
        var latest = try other.settings()
        latest.promptRetentionDays = lengthen ? 30 : 1
        try other.saveSettings(latest, at: 0)
      }
      _ = try store.cleanRetention(at: 30 * 86400 + 400)
      XCTAssertTrue(changed)
      store.connection.collectionMaintenanceGap = nil
      let reopened = try open(folder)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM evidence WHERE kind='prompt'"), lengthen ? 1 : 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations"), 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM collection_metadata"), 300)
    }
  }

  func testLatePipelineAndCanonicalCollectionCanReuseErasedRowIDsWithoutScrubbingAllowedMetadata() throws {
    for retention in [false, true] {
      let (folder, store) = try fixture(), writer = try open(folder, busy: 0)
      try store.appendObservations((0..<320).map { ActivityObservation(id: "invented-old-\($0)",
        sample: TimeSample(ts: 100 + $0 / 2, bundleID: "invented")) })
      try store.appendSamples([TimeSample(ts: 100, bundleID: "invented", window: "Invented old", observedAt: 100.5)])
      for index in 0..<320 {
        _ = try store.storeScreenCapture(text: "Invented old", at: 100 + index / 2, source: "invented",
          documentKey: "invented-old", project: "", knownKeys: [], probe: nil,
          payload: ScreenTextPayload(text: "Invented old", document: "invented-old"),
          occurrenceID: "invented-old-\(index)", metadataObservedAt: 100.5)
      }
      let pipeline = CollectionPipeline(writer: writer), preview = try store.previewDeletion(in: TimeRange(100,400))
      var offered = false
      store.connection.collectionMaintenanceGap = {
        self.assertGap(store)
        guard !offered,
          try store.connection.integer("SELECT count(*) FROM sample_observations WHERE ts<400") == 0,
          try store.connection.integer("SELECT count(*) FROM evidence WHERE ts<400") == 0 else { return }
        offered = true
        XCTAssertTrue(pipeline.offer(ActivityObservation(id: "invented-new", sample: TimeSample(ts: 600,
          bundleID: "invented", window: "Invented new", observedAt: 600.5))))
        pipeline.drain()
        XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented new", document: "invented-new"),
          at: 600, source: "invented", documentKey: "invented-new", runID: nil, attemptID: nil, metadataObservedAt: 600.5))
        pipeline.drain()
        XCTAssertEqual(try writer.appendAccountingSamples([TimeSample(ts: 601, bundleID: "invented",
          window: "Invented new", documentKey: "invented-new", observedAt: 600.5)]).stored, 1)
        XCTAssertEqual(try writer.connection.integer("SELECT id FROM sample_observations WHERE observation_id='invented-new'"), 1)
        XCTAssertEqual(try writer.connection.integer("SELECT id FROM evidence WHERE ts=600"), 1)
        if !retention { XCTAssertEqual(try writer.connection.integer("SELECT id FROM samples WHERE ts=601"), 1) }
      }
      if retention { _ = try store.cleanRetention(at: 30 * 86400 + 400) }
      else { try store.deleteRecords(in: preview.range, confirmation: preview.confirmation) }
      store.connection.collectionMaintenanceGap = nil
      XCTAssertTrue(offered)
      XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      let reopened = try open(folder)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations WHERE ts<400"), 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM evidence WHERE ts<400"), 0)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM sample_observations WHERE observation_id='invented-new' AND observed_ts=600"), 1)
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM samples WHERE ts=601 AND observed_ts=600 AND window='Invented new' AND document_key='invented-new'"), 1)
      XCTAssertEqual(try reopened.screenPayload(evidenceID: 1)?.document, "invented-new")
      XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM screen_payloads WHERE evidence_id=1 AND metadata_ts=600"), 1)
      XCTAssertTrue(try reopened.collectionFiles().isEmpty)
    }
  }

  func testMetadataScrubDerivesBlobDedupStateAfterConcurrentPipelineCheckpoint() throws {
    let (folder, store) = try fixture(), writer = try open(folder, busy: 0)
    try store.appendObservations((0..<64).map { ActivityObservation(id: "invented-old-\($0)", sample: TimeSample(ts: 100, bundleID: "invented")) })
    _ = try store.storeScreenCapture(text: "Invented", at: 600, source: "invented", documentKey: "invented",
      project: "", knownKeys: [], probe: nil, payload: ScreenTextPayload(text: "Invented", document: "invented"),
      occurrenceID: "invented-original", metadataObservedAt: 100.5)
    let originalID = try store.connection.integer("SELECT id FROM evidence WHERE ts=600")
    let scrubbed = ScreenTextPayload(text: "Invented"), hash = probeHash(try screenPayloadJSON(scrubbed))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_blobs WHERE hash=?", [.key(hash)]), 0)
    let pipeline = CollectionPipeline(writer: writer)
    var offered = false
    store.connection.collectionMaintenanceGap = {
      self.assertGap(store)
      guard !offered else { return }; offered = true
      XCTAssertTrue(pipeline.offer(payload: scrubbed, at: 700, source: "invented", documentKey: "", runID: nil, attemptID: nil))
      pipeline.drain()
      XCTAssertEqual(try writer.connection.integer("SELECT created_ts FROM collection_blobs WHERE hash=?", [.key(hash)]), 700)
    }
    let journal = try ModelCallJournal(database: store.url)
    try journal.withMaintenanceLock(store.connection) {
      try store.connection.transaction(collectionMaintenance: true) {
        try store.connection.run("INSERT INTO forgotten_ranges VALUES(100,101)")
        try store.connection.enableCollectionMaintenanceBatches()
        // Sixty-four real bounded changes make the next unit checkpoint. The
        // dedup lookup must occur after the pipeline inserts in that gap.
        try store.connection.withCollectionMaintenanceUnit {
          try store.connection.collectionWrite("DELETE FROM sample_observations WHERE ts=100")
        }
        let expected = try store.scrubScreenMetadata(ids: [originalID])
        try store.verifyScreenMetadataErasure(expected)
      }
    }
    store.connection.collectionMaintenanceGap = nil
    XCTAssertTrue(offered)
    XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
    let reopened = try open(folder)
    XCTAssertEqual(try reopened.screenPayload(evidenceID: originalID), scrubbed)
    XCTAssertEqual(try reopened.connection.integer("SELECT created_ts FROM collection_blobs WHERE hash=?", [.key(hash)]), 700)
    XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM screen_payloads WHERE payload_hash=?", [.key(hash)]), 2)
    XCTAssertTrue(try reopened.collectionFiles().isEmpty)
  }

  func testCheckpointRejectsOpenSourceStatementBeforeAnyCommit() throws {
    let (_, store) = try fixture()
    try store.appendObservations(observations(0..<100, metadata: 500.5))
    XCTAssertThrowsError(try store.connection.transaction(collectionMaintenance: true) {
      try store.connection.enableCollectionMaintenanceBatches()
      try store.connection.collectionWrite("DELETE FROM sample_observations WHERE ts<125")
      try store.connection.namedRows("SELECT id FROM sample_observations") { _ in
        store.connection.collectionBatchChanges = 64
        try store.connection.withCollectionMaintenanceUnit { }
      }
    }) { XCTAssertTrue(String(describing: $0).contains("Open statement")) }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sample_observations"), 100)
  }
}
