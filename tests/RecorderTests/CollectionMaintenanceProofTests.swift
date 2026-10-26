import Core
import Foundation
import XCTest
@testable import Storage

final class CollectionMaintenanceProofTests: XCTestCase {
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
  func testUniqueConflictPlansMaterializeOnlyApplicableSQLiteKeys() throws {
    for count in [0, 256, 1024, 4096] {
      try store.connection.run("DELETE FROM evidence")
      try store.connection.run("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<?) INSERT INTO evidence(ts,kind,source,document_key,project,text) SELECT x,'screen','invented','','','' FROM n WHERE x<=?", [.integer(count), .integer(count)])
      try store.connection.run("INSERT OR IGNORE INTO collection_blobs VALUES('invented-text','Invented',0),('invented-json','{}',0)")
      try store.connection.run("INSERT INTO screen_payloads(evidence_id,payload,text_hash,payload_hash,novel_text,occurrence_id) SELECT id,'','invented-text','invented-json','','invented-'||id FROM evidence")
      try store.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(10,'prompt','invented','genuine','','','')")
      // This additional partial index exercises both incoming applicability and
      // retained rows outside its predicate, with a non-NULL key.
      try store.connection.run("CREATE UNIQUE INDEX IF NOT EXISTS invented_partial ON evidence(document_key COLLATE NOCASE) \nWHERE kind='prompt' AND document_key!=''")
      try store.connection.run("INSERT INTO evidence(ts,kind,source,document_key,project,text) VALUES(11,'prompt','other','partial','',''),(12,'screen','other','outside','','')")
      for (sourceID, kind, document, conflictTime) in [(SQLValue.null, "screen", "", 1), (.key("genuine"), "screen", "", 10), (.null, "screen", "partial", 1), (.null, "prompt", "partial", 11), (.null, "prompt", "PARTIAL", 11), (.null, "prompt", "outside", 1)] {
        try store.connection.transaction {
          let proof = try CollectionMaintenanceProof(store.connection)
          try proof.apply("INSERT OR IGNORE INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(20,?,'invented',?,?,'','')", [.text(kind), sourceID, .key(document)], source: store.connection)
          XCTAssertEqual(try proof.expected.integer("SELECT count(*) FROM evidence"), 1, "history=\(count) kind=\(kind) document=\(document)")
          XCTAssertEqual(try proof.expected.integer("SELECT count(*) FROM screen_payloads"), 0)
          XCTAssertEqual(try proof.expected.integer("SELECT count(*) FROM evidence WHERE ts=?", [.integer(conflictTime == 1 ? 20 : conflictTime)]), 1)
        }
      }
      try store.connection.run("DROP INDEX invented_partial")
    }
  }

  func testProductionPipelinePersistsBetweenPrivacyMaintenanceBatches() throws {
    for retention in [false, true] {
      let child = CollectionMaintenanceProofTests(); try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let writer = try ActivityStorage(url: child.store.url, appDataDirectory: child.folder, busyMilliseconds: 0, databaseScope: .directory(child.folder))
      let pipeline = CollectionPipeline(writer: writer)
      let value = ActivityObservation(id: "invented-seed", sample: TimeSample(ts: 100, bundleID: "invented"))
      let template = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      try child.store.connection.run("WITH RECURSIVE n(x) AS (VALUES(100) UNION ALL SELECT x+1 FROM n WHERE x<8291) INSERT INTO sample_observations(observation_id,ts,payload) SELECT 'invented-'||x,x,json_set(?,'$.id','invented-'||x,'$.sample.ts',x) FROM n", [.maskedText(template)])
      let range = TimeRange(100,8292), preview = try child.store.previewDeletion(in: range)
      let committed = expectation(description: "Allowed observation commits before maintenance finishes")
      var offered = false
      child.store.connection.collectionCommitClock = {
        if !offered {
          offered = true
          DispatchQueue.global().async {
            let began = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(pipeline.offer(ActivityObservation(id: "invented-allowed", sample: TimeSample(ts: 9000, bundleID: "invented"))))
            pipeline.drain()
            do {
              XCTAssertEqual(try writer.connection.integer("SELECT count(*) FROM sample_observations WHERE observation_id='invented-allowed'"), 1)
              XCTAssertGreaterThan(try writer.connection.integer("SELECT count(*) FROM sample_observations WHERE ts<8292"), 0)
            } catch { XCTFail("\(error)") }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-began, 1)
            XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
            committed.fulfill()
          }
        }
        return 200_000
      }
      if retention { _ = try child.store.cleanRetention(at: 30 * 86400 + 8292) }
      else { try child.store.deleteRecords(in: range, confirmation: preview.confirmation) }
      wait(for: [committed], timeout: 3)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM sample_observations"), 1)
      XCTAssertTrue(try child.store.collectionFiles().isEmpty)
      XCTAssertEqual(try child.store.appendObservations([value]).stored, 0)
    }
  }

  func erase(retention: Bool) throws {
    if retention { _ = try store.cleanRetention(at: 30 * 86400 + 101) }
    else {
      let preview = try store.previewDeletion(in: TimeRange(100,101))
      try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    }
  }
  func testPrivacyPreservationCannotInjectInputAcrossForgetRetentionControlsAndRestart() throws {
    for retention in [false, true] { for fault in [false, true] {
      let child = CollectionMaintenanceProofTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      try child.store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 99)
      try child.store.saveSettings(StorageSettings(excludedApps: []), at: 100)
      if retention {
        let preview = try child.store.previewDeletion(in: TimeRange(102,103))
        try child.store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
      }
      let value = ActivityObservation(id: "invented-parent", sample: TimeSample(ts: 100, bundleID: "invented", window: "Invented", inputEvents: [InputObservation(kind: .move, timestamp: 101.25)], observedAt: 101.5))
      try child.store.appendObservations([value])
      let second = retention ? 102 : 99
      if fault {
        let bytes = CompactInput.encode([InputObservation(kind: .move, timestamp: Double(second)+0.5)]).map { String(format: "%02x", $0) }.joined()
        try child.store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON collection_metadata BEGIN INSERT INTO input_batches(observation_id,ts,events) VALUES(NEW.identity,\(second),X'\(bytes)'); END")
        XCTAssertThrowsError(try child.erase(retention: retention))
        XCTAssertEqual(try child.store.observations(in: TimeRange(100,101)).count, 1)
        XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_metadata"), 0)
        XCTAssertEqual(try child.store.inputEvents(in: TimeRange(second,second+1)).count, 0)
        try child.store.connection.run("DROP TRIGGER invented_fault")
        try child.reopen()
      }
      try child.erase(retention: retention)
      XCTAssertEqual(try child.store.observations(in: TimeRange(100,101)).count, 0)
      XCTAssertEqual(try child.store.inputEvents(in: TimeRange(second,second+1)).count, 0)
      XCTAssertEqual(try child.store.inputEvents(in: TimeRange(101,102)).count, 1)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_metadata"), 1)
      try child.reopen()
      try child.erase(retention: retention)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_metadata"), 1)
    } }
  }
  func testPrivacyReplacementBlobUsesTransactionEntryStateWithControlsDedupAndRestart() throws {
    for retention in [false, true] { for preexisting in [false, true] { for fault in [false, true] {
      let child = CollectionMaintenanceProofTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let payload = ScreenTextPayload(text: "Invented OCR retained", document: "invented-document", browserAddress: "invented-address")
      var scrubbed = payload; scrubbed.document = nil; scrubbed.browserAddress = nil
      let json = try screenPayloadJSON(scrubbed), hash = probeHash(json)
      if preexisting {
        _ = try child.store.storeScreenCapture(text: scrubbed.text, at: 99, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: scrubbed, occurrenceID: "invented-existing")
      }
      _ = try child.store.storeScreenCapture(text: payload.text, at: 101, source: "invented", documentKey: "invented", project: "", knownKeys: [], probe: nil, payload: payload, occurrenceID: "invented-occurrence", metadataObservedAt: 100.5)
      try child.store.appendObservations([ActivityObservation(id: "invented-parent", sample: TimeSample(ts: 101, bundleID: "invented", window: "Invented", inputEvents: [InputObservation(kind: .move, timestamp: 100.5)], observedAt: 100.5))])
      if fault {
        var faulty = scrubbed; faulty.text = "Invented changed"; faulty.blockHypotheses = ["invented-document"]
        let bytes = Data(try screenPayloadJSON(faulty).utf8).map { String(format: "%02x", $0) }.joined()
        let mutation = preexisting ? "UPDATE collection_blobs SET content=CAST(X'\(bytes)' AS TEXT),created_ts=888 WHERE hash='\(hash)'" : "INSERT OR IGNORE INTO collection_blobs(hash,content,created_ts) VALUES('\(hash)',CAST(X'\(bytes)' AS TEXT),888)"
        try child.store.connection.run("CREATE TRIGGER invented_fault AFTER UPDATE ON sample_observations BEGIN \(mutation); END")
        XCTAssertThrowsError(try child.erase(retention: retention))
        let id = try child.store.connection.integer("SELECT evidence_id FROM screen_payloads WHERE occurrence_id='invented-occurrence'")
        XCTAssertEqual(try child.store.screenPayload(evidenceID: id), payload)
        XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_blobs WHERE created_ts=888"), 0)
        try child.store.connection.run("DROP TRIGGER invented_fault")
        try child.reopen()
      }
      try child.erase(retention: retention)
      let id = try child.store.connection.integer("SELECT evidence_id FROM screen_payloads WHERE occurrence_id='invented-occurrence'")
      XCTAssertEqual(try child.store.screenPayload(evidenceID: id), scrubbed)
      XCTAssertEqual(try child.store.connection.integer("SELECT created_ts FROM collection_blobs WHERE hash=?", [.key(hash)]), preexisting && !retention ? 99 : 101)
      try child.reopen()
      try child.erase(retention: retention)
      XCTAssertEqual(try child.store.screenPayload(evidenceID: id), scrubbed)
    } } }
  }
  func testMaintenanceRejectsDirectCollectionWriteBypassAndFinalNoncollectionSideEffect() throws {
    XCTAssertThrowsError(try store.connection.transaction(collectionMaintenance: true) {
      try store.connection.run("INSERT INTO input_batches(observation_id,ts,events) VALUES('invented',100,X'0100')")
    })
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches"), 0)
    try store.connection.run("CREATE TRIGGER invented_fault AFTER INSERT ON forgotten_ranges BEGIN INSERT INTO input_batches(observation_id,ts,events) VALUES('invented',99,X'0100'); END")
    XCTAssertThrowsError(try store.connection.transaction(collectionMaintenance: true) {
      try store.connection.run("INSERT INTO forgotten_ranges VALUES(100,101)")
    })
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches"), 0)
    try store.connection.run("DROP TRIGGER invented_fault")
    try reopen()
    try erase(retention: false)
  }
  func testMaintenanceRepairProvesAllColumnsAndRetainsRetryAcrossReopen() throws {
    let payload = ScreenTextPayload(text: "Invented repair")
    _ = try store.storeScreenCapture(text: payload.text, at: 101, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: payload, occurrenceID: "invented-repair")
    try store.connection.run("UPDATE screen_payloads SET novel_text=NULL")
    try store.connection.run("CREATE TRIGGER invented_fault AFTER UPDATE OF novel_text ON screen_payloads BEGIN UPDATE collection_blobs SET created_ts=888; END")
    XCTAssertThrowsError(try store.connection.transaction(collectionMaintenance: true) { try store.repairCollectionNovelty() })
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"), 1)
    try reopen() // Best-effort open repair must also roll back the injected mutation.
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_blobs WHERE created_ts=888"), 0)
    try store.connection.run("DROP TRIGGER invented_fault")
    try reopen()
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"), 0)
  }
  func testFailedDerivedRepairDoesNotBlockNewCaptureOrRecovery() throws {
    for recovery in [false, true] {
      let child = CollectionMaintenanceProofTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      let payload = ScreenTextPayload(text: "Invented repair isolation")
      _ = try child.store.storeScreenCapture(text: payload.text, at: 101, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: payload, occurrenceID: "invented-old")
      try child.store.connection.run("UPDATE screen_payloads SET novel_text=NULL")
      try child.store.connection.run("CREATE TRIGGER invented_fault AFTER UPDATE OF novel_text ON screen_payloads BEGIN UPDATE collection_blobs SET created_ts=888; END")
      if recovery {
        try child.store.stageCollection(CollectionRecord(screen: payload, time: 102, source: "invented", occurrenceID: "invented-new"))
        let pipeline = child.store.makeCollectionPipeline(); pipeline.drain()
        XCTAssertTrue(try child.store.collectionFiles().isEmpty)
        XCTAssertEqual(pipeline.takeDiagnostics().persistenceFailures, 0)
      } else {
        _ = try child.store.storeScreenCapture(text: payload.text, at: 102, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: payload, occurrenceID: "invented-new")
      }
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM screen_payloads"), 2)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"), 2)
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM collection_blobs WHERE created_ts=888"), 0)
      try child.store.connection.run("DROP TRIGGER invented_fault")
      try child.reopen()
      XCTAssertEqual(try child.store.connection.integer("SELECT count(*) FROM screen_payloads WHERE novel_text IS NULL"), 0)
    }
  }
  func testPrivacyDedupStillRequiresPreparedContentWithControls() throws {
    for blob in [false, true] { for fault in [false, true] {
      let child = CollectionMaintenanceProofTests()
      try child.setUpWithError()
      defer { try! child.tearDownWithError() }
      if blob {
        let original = ScreenTextPayload(text: "Invented retained", document: "invented-document")
        var scrubbed = original; scrubbed.document = nil
        _ = try child.store.storeScreenCapture(text: scrubbed.text, at: 99, source: "invented", documentKey: "", project: "", knownKeys: [], probe: nil, payload: scrubbed, occurrenceID: "invented-baseline")
        _ = try child.store.storeScreenCapture(text: original.text, at: 101, source: "invented", documentKey: "invented", project: "", knownKeys: [], probe: nil, payload: original, occurrenceID: "invented-retained", metadataObservedAt: 100.5)
        if fault {
          let hash = probeHash(try screenPayloadJSON(scrubbed))
          try child.store.connection.run("UPDATE collection_blobs SET content=? WHERE hash=?", [.maskedText(try screenPayloadJSON(ScreenTextPayload(text: "Invented wrong"))), .key(hash)])
        }
      } else {
        let value = ActivityObservation(id: "invented-metadata", sample: TimeSample(ts: 100, bundleID: "invented", window: "Invented", observedAt: 101.5))
        try child.store.appendObservations([value])
        try child.store.connection.transaction {
          try child.store.withCollectionAdmission(CollectionRecord(observation: value, time: 100, eventsOnly: true)) {
            try child.store.insertIndependentMetadata($0)
          }
        }
        if fault { try child.store.connection.run("UPDATE collection_metadata SET payload='{}'") }
      }
      if fault {
        XCTAssertThrowsError(try child.erase(retention: false))
        try child.reopen()
        XCTAssertThrowsError(try child.erase(retention: false))
      } else { try child.erase(retention: false) }
    } }
  }
  func testEveryCollectionTableRejectsUnregisteredMaintenanceWrites() throws {
    for table in CollectionMaintenanceProof.tables.sorted() {
      XCTAssertThrowsError(try store.connection.transaction(collectionMaintenance: true) {
        try store.connection.run("DELETE FROM \(table) WHERE 0")
      }, table)
      try store.connection.transaction(collectionMaintenance: true) {
        try store.connection.collectionWrite("DELETE FROM \(table) WHERE 0")
      }
    }
  }
  func testMaintenanceHelpersRequireTransactionEntryProof() throws {
    let operations: [() throws -> Void] = [
      { try self.store.preserveCollectionMetadata(in: TimeRange(100,101)) },
      { _ = try self.store.scrubObservationMetadata(in: TimeRange(100,101)) },
      { _ = try self.store.scrubScreenMetadata(ids: []) },
      { _ = try self.store.scrubSampleMetadata(ids: []) },
      { try self.store.repairCollectionNovelty() },
      { try self.store.verifyCollectionErasure(ids: []) },
      { try self.store.connection.createCollectionSchema() },
      { try self.store.connection.backfillCollectionNovelty() }
    ]
    for operation in operations { XCTAssertThrowsError(try store.connection.transaction(operation)) }
  }
  func testCollectionWriteSiteInventoryRequiresProofReview() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("Sources/Storage")
    let reviewed: [String: [String: Int]] = [
      "CollectionObservations.swift": ["collection_legacy_times": 2, "screen_payloads": 4, "collection_blobs": 2, "sample_observations": 4, "samples": 1, "input_batches": 1],
      "ActivityStorage.swift": ["samples": 2, "evidence": 3, "screen_payloads": 1, "collection_retention": 1, "collection_metadata": 1, "sample_observations": 1, "input_batches": 1, "collection_legacy_times": 1],
      "CollectionAccounting.swift": ["collection_ingestion_pending": 3, "collection_ingestion": 2],
      "CollectionPolicy.swift": ["collection_policy_refusals": 1, "collection_metadata": 1, "collection_metadata_erasure_proof": 3, "sample_observations": 1],
      "CollectionMaintenanceProof.swift": ["collection_blobs": 1],
      "ScreenMetadata.swift": ["screen_payloads": 1, "evidence": 1, "samples": 1]
    ]
    let dml = try NSRegularExpression(pattern: #"\b(?:INSERT(?: OR (?:IGNORE|REPLACE))? INTO|UPDATE|DELETE FROM)\s+(samples|evidence|sample_observations|input_batches|screen_payloads|collection_[a-z_]+)\b"#)
    let bypass = try NSRegularExpression(pattern: #"\brun\(\s*"{1,3}\s*(?:INSERT(?: OR (?:IGNORE|REPLACE))? INTO|UPDATE|DELETE FROM)\s+(samples|evidence|sample_observations|input_batches|screen_payloads|collection_[a-z_]+)\b"#)
    let tableCreation = try NSRegularExpression(pattern: #"CREATE TABLE IF NOT EXISTS (collection_[a-z_]+)\b"#)
    var actual: [String: [String: Int]] = [:]
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
      let source = try String(contentsOf: file)
      let range = NSRange(source.startIndex..., in: source)
      for match in tableCreation.matches(in: source, range: range) {
        let table = String(source[Range(match.range(at: 1), in: source)!])
        XCTAssertTrue(CollectionMaintenanceProof.tables.contains(table), "Register the collection table in the shared proof: " + table)
      }
      for match in dml.matches(in: source, range: range) {
        let table = String(source[Range(match.range(at: 1), in: source)!])
        actual[file.lastPathComponent, default: [:]][table, default: 0] += 1
      }
      XCTAssertTrue(bypass.matches(in: source, range: range).isEmpty, "Collection DML must use collectionWrite: " + file.lastPathComponent)
    }
    XCTAssertEqual(actual, reviewed, "A collection write site changed. Review both rules and update the coverage inventory.")
    let deletion = try String(contentsOf: directory.appendingPathComponent("Deletion.swift"))
    XCTAssertTrue(deletion.contains(#"connection.collectionWrite("DELETE FROM \(table) WHERE \(selection)"#))
    XCTAssertTrue(deletion.contains("transaction(collectionMaintenance: true)"))
    let conversion = try String(contentsOf: directory.appendingPathComponent("Conversion.swift"))
    XCTAssertTrue(conversion.contains(#"transaction(collectionMaintenance: name == "samples" || name == "evidence")"#))
  }

}
