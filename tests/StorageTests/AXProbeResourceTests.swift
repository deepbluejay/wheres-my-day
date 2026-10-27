import Core
import Foundation
import SQLite3
import XCTest
@testable import Storage

extension StorageTests {
  private func resourcePair(_ store: ActivityStorage, at now: Int = 10001) throws -> AXProbePair {
    let run = try store.settings().axProbeRun ?? store.enableAXProbe(at: now - 1)
    let request = AXProbeRequest(run: run, time: now, window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.app", isBrowser: false)
    return AXProbePair(request: request, ax: AXProbeResult(status: .completed), ocrStatus: "completed", ocr: "Invented OCR", imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
  }
  func testAXProbeUnsupportedVersionEightLeavesLegacyPayloadUnchanged() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let pair = try resourcePair(store)
    let legacy = String(decoding: try JSONEncoder().encode(pair), as: UTF8.self)
    try store.connection.run("UPDATE ax_probe_runs SET probe_version=2")
    try store.connection.run("INSERT INTO ax_probe_attempts(run_id,attempt_id,ts,mapping_key,payload) VALUES(?,?,?,?,?)", [.key(pair.runID), .key(pair.attemptID), .integer(pair.time), .key("invented-key"), .maskedText(legacy)])
    for trigger in ["ax_probe_content_delete", "ax_probe_unref", "ax_probe_blob_delete", "ax_probe_content_refused"] { try store.connection.run("DROP TRIGGER \(trigger)") }
    for table in ["ax_probe_parts", "ax_probe_refs", "ax_probe_chunks", "ax_probe_blobs"] { try store.connection.run("DROP TABLE \(table)") }
    try store.connection.run("PRAGMA user_version=8")
    XCTAssertThrowsError(try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder)))
    let upgraded = try ActivityStorage(url: url, appDataDirectory: folder, readOnly: true, databaseScope: .directory(folder))
    XCTAssertEqual(try upgraded.connection.integer("PRAGMA user_version"), 8)
    XCTAssertEqual(try upgraded.connection.integer("SELECT probe_version FROM ax_probe_runs"), 2)
    try upgraded.connection.rows("SELECT payload FROM ax_probe_attempts") { XCTAssertEqual(SQLiteConnection.text($0, 0), legacy) }
    XCTAssertEqual(try upgraded.connection.integer("SELECT count(*) FROM sqlite_master WHERE name='ax_probe_blobs'"), 0)
  }
  func testAXProbeStatusReportsCurrentRetainedBytesAddedWithinTwentyFourHours() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let now = Int(Date().timeIntervalSince1970)
    var pair = try resourcePair(store, at: now)
    pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: "Invented current observation")])]
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: now))
    let total = try store.probeStorageBytes(since: nil), recent = try store.probeStorageBytes(since: now - 86400)
    XCTAssertGreaterThan(total, 0); XCTAssertEqual(total, recent)
    let status = try store.axProbeStatus()
    XCTAssertTrue(status.contains("ax_probe_storage_bytes=\(total) ax_probe_added_24h_bytes=\(recent)"))
  }
  func testAXProbeMetadataAndEveryNonconstantStringAreMaskedInAllTables() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store)
    pair.ax.nodes = [AXProbeNode(nodeID: 1, role: "password=inventedRoleCredential", subrole: "password=inventedSubroleCredential",
      bundleID: "password=inventedBundleCredential", attributes: [AXProbeText(attribute: "password=inventedAttributeCredential", text: "password=inventedValueCredential")])]
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    try store.connection.rows("SELECT text FROM ax_probe_chunks UNION ALL SELECT payload FROM ax_probe_attempts") {
      XCTAssertFalse(SQLiteConnection.text($0, 0).contains("Credential"))
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs WHERE complete=0"), 0)
    // Four different secret-shaped fields collapse to the same masked content blob.
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE text='[secret]'"), 1)
  }
  func testAXProbeDedupAndForgetRemoveOnlyUnreferencedTextIncludingPhysicalBytes() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var first = try resourcePair(store)
    first.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: "Invented shared observation"), AXProbeText(attribute: "AXHelp", text: "Invented forget-only observation")])]
    first.ax.nodes?[0].readSeconds = 0.004
    XCTAssertTrue(try store.appendAXProbe(first, evidenceID: nil, at: first.time))
    let firstBlobs = try store.connection.integer("SELECT count(*) FROM ax_probe_blobs")
    var second = first; second.time += 15; second.attemptID = UUID().uuidString
    second.ax.nodes?[0].readSeconds = 0.009
    XCTAssertTrue(try store.appendAXProbe(second, evidenceID: nil, at: second.time))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs"), firstBlobs)
    let before = try store.connection.integer("SELECT count(*) FROM ax_probe_chunks")
    var kept = second; kept.time += 15; kept.attemptID = UUID().uuidString; kept.ax.nodes?[0].attributes.removeLast()
    XCTAssertTrue(try store.appendAXProbe(kept, evidenceID: nil, at: kept.time))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE text='Invented shared observation'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE text='Invented forget-only observation'"), 1)
    XCTAssertGreaterThan(before, 0)
    let preview = try store.previewDeletion(in: TimeRange(first.time, kept.time))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE instr(text,'forget-only')>0"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE instr(text,'shared observation')>0"), 1)
    XCTAssertFalse(try store.appendAXProbe(first, evidenceID: nil, at: kept.time))
    XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Invented forget-only observation"))
    let runPreview = try store.previewAXProbeDeletion(run: first.runID)
    _ = try store.deleteAXProbe(run: first.runID, confirmation: runPreview.confirmation)
    for table in ["ax_probe_refs", "ax_probe_parts", "ax_probe_blobs", "ax_probe_chunks"] {
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table)"), 0)
    }
  }
  func testAXProbeHugeStringsAreExplicitAndAcceptedLargeStringsUseSmallChunks() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store)
    let large = String(repeating: "z", count: 1024 * 1024)
    let huge = String(repeating: "q", count: AXProbeResources.stringUTF16 + 1)
    pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: large), AXProbeText(attribute: "AXHelp", text: huge)])]
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    XCTAssertEqual(try store.connection.integer("SELECT MAX(length(CAST(text AS BLOB))) FROM ax_probe_chunks"), AXProbeResources.chunkBytes)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE instr(text,'qqqq')>0"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT json_extract(payload,'$.ax.counts.resource_truncated_original_utf16') FROM ax_probe_attempts"), huge.utf16.count)
    XCTAssertEqual(try store.connection.integer("SELECT json_extract(payload,'$.ax.truncations.resource_truncated') FROM ax_probe_attempts"), 1)
  }
  func testAXProbeFiftyThousandNodesPersistThroughByteAccountedPipeline() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store)
    pair.ax.nodes = (0..<50000).map { AXProbeNode(nodeID: $0, role: "AXStaticText", attributes: [AXProbeText(attribute: "AXValue", text: "Invented repeated leaf")]) }
    pair.ax.elements = 50000
    let pipeline = AXProbePipeline(write: { pair, _, now, gate in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: now, permitted: gate))
    }, dropped: { _ in XCTFail("Invented tree fits the declared memory envelope") })
    let receipt = try XCTUnwrap(pipeline.offer(pair, permitted: { true }))
    XCTAssertLessThanOrEqual(pipeline.reservedBytes, AXProbeResources.attemptBytes)
    pipeline.commit(receipt, evidenceID: nil, at: pair.time)
    let done = expectation(description: "all nodes persisted")
    pipeline.drain { done.fulfill() }; wait(for: [done], timeout: 180)
    XCTAssertEqual(pipeline.reservedBytes, 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_parts"), 3125)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE text='Invented repeated leaf'"), 1)
    XCTAssertLessThanOrEqual(try store.connection.integer("SELECT MAX(length(CAST(text AS BLOB))) FROM ax_probe_chunks"), AXProbeResources.chunkBytes)
  }
  func testAXProbeForgetAndPolicyChangesBetweenChunksCannotRetainPartialText() throws {
    for forget in [true, false] {
      let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
      var pair = try resourcePair(store, at: forget ? 10001 : 10101)
      pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: String(repeating: "Invented partial observation ", count: 10000))])]
      var checks = 0
      XCTAssertThrowsError(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time, permitted: {
        checks += 1
        if checks == 10 {
          if forget {
            let preview = try! store.previewDeletion(in: TimeRange(pair.time, pair.time + 1))
            _ = try! store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
          } else {
            var settings = try! store.settings(); settings.recordingEnabled = false; try! store.saveSettings(settings)
          }
        }
        return true
      }))
      for table in ["ax_probe_parts", "ax_probe_refs", "ax_probe_blobs", "ax_probe_chunks"] {
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table)"), 0)
      }
      let preview = try store.previewAXProbeDeletion(run: pair.runID)
      _ = try store.deleteAXProbe(run: pair.runID, confirmation: preview.confirmation)
      var settings = try store.settings(); settings.recordingEnabled = true; try store.saveSettings(settings)
    }
  }
  func testAXProbeGenerationInvalidationBeforeCommitRollsBackAndCleansChunks() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store)
    pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: String(repeating: "Invented generation text ", count: 10000))])]
    var checks = 0
    XCTAssertThrowsError(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time, permitted: { checks += 1; return checks < 5 }))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs"), 0)
  }
  func testAXProbeRetentionAndEvidenceCascadeCleanDeduplicatedBlobs() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var settings = try store.settings(); settings.screenRetentionDays = 1; try store.saveSettings(settings)
    var pair = try resourcePair(store)
    let evidence = try store.appendScreenCapture(text: "Invented evidence", at: pair.time, source: "invented.app", knownKeys: [])
    pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: "Invented retention content")])]
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: pair.time))
    try store.connection.run("DELETE FROM evidence WHERE id=?", [.integer(evidence.evidenceID!)])
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs"), 0)
    pair.attemptID = UUID().uuidString
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    _ = try store.cleanRetention(at: pair.time + 86401)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks"), 0)
  }
  private func probeContentSnapshot(_ store: ActivityStorage) throws -> [String: [[String]]] {
    var snapshot: [String: [[String]]] = [:]
    for (table, order) in [("ax_probe_attempts", "id"), ("ax_probe_refs", "attempt_row,hash"),
      ("ax_probe_parts", "attempt_row,ordinal"), ("ax_probe_blobs", "hash"), ("ax_probe_chunks", "hash,ordinal")] {
      var rows: [[String]] = []
      try store.connection.rows("SELECT * FROM \(table) ORDER BY \(order)") { row in
        rows.append((0..<sqlite3_column_count(row)).map { SQLiteConnection.text(row, $0) })
      }
      snapshot[table] = rows
    }
    return snapshot
  }
  private func verifyForgottenWriterCannotTouchReusedRow(runForget: Bool) throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var old = try resourcePair(store)
    old.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue",
      text: String(repeating: "Invented interrupted content ", count: 10000))])]
    let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let finished = expectation(description: "forgotten writer rejected")
    DispatchQueue.global().async {
      var checks = 0
      do {
        _ = try store.appendAXProbe(old, evidenceID: nil, at: old.time, permitted: {
          checks += 1
          if checks == 10 {
            paused.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 30), .success)
          }
          return true
        })
        XCTFail("forgotten writer must fail")
      } catch {}
      finished.fulfill()
    }
    defer { resume.signal() }
    XCTAssertEqual(paused.wait(timeout: .now() + 10), .success)
    let originalRow = try store.connection.integer("SELECT id FROM ax_probe_attempts")
    XCTAssertGreaterThan(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks"), 0)
    if runForget {
      let preview = try store.previewAXProbeDeletion(run: old.runID)
      _ = try store.deleteAXProbe(run: old.runID, confirmation: preview.confirmation)
    } else {
      let preview = try store.previewDeletion(in: TimeRange(old.time, old.time + 1))
      _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    }
    var kept = try resourcePair(store, at: old.time + 15)
    kept.ax.nodes = [AXProbeNode(nodeID: 1, role: "AXStaticText",
      attributes: [AXProbeText(attribute: "AXValue", text: "Invented kept observation")])]
    XCTAssertTrue(try store.appendAXProbe(kept, evidenceID: nil, at: kept.time))
    XCTAssertEqual(try store.connection.integer("SELECT id FROM ax_probe_attempts"), originalRow)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='completed'"), 1)
    for table in ["ax_probe_parts", "ax_probe_refs", "ax_probe_blobs", "ax_probe_chunks"] {
      XCTAssertGreaterThan(try store.connection.integer("SELECT count(*) FROM \(table)"), 0)
    }
    let expected = try probeContentSnapshot(store)
    resume.signal(); wait(for: [finished], timeout: 10)
    XCTAssertEqual(try probeContentSnapshot(store), expected)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs WHERE NOT EXISTS(SELECT 1 FROM ax_probe_refs WHERE ax_probe_refs.hash=ax_probe_blobs.hash)"), 0)
  }
  func testAXProbeRangeForgetReusedRowKeepsExactCompletedContent() throws {
    try verifyForgottenWriterCannotTouchReusedRow(runForget: false)
  }
  func testAXProbeRunForgetReusedRowKeepsExactNewRunContent() throws {
    try verifyForgottenWriterCannotTouchReusedRow(runForget: true)
  }
  private func verifyProbeGraphPreviewFreshness(runForget: Bool) throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store); pair.ax.status = .pending
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    let row = try store.connection.integer("SELECT id FROM ax_probe_attempts")
    let header = try probeContentSnapshot(store)["ax_probe_attempts"]
    let preview = { () throws -> DeletionPreview in
      try runForget ? store.previewAXProbeDeletion(run: pair.runID) : store.previewDeletion(in: TimeRange(pair.time, pair.time + 1))
    }
    let remove = { (code: String) throws -> Void in
      if runForget { _ = try store.deleteAXProbe(run: pair.runID, confirmation: code) }
      else { _ = try store.deleteRecords(in: TimeRange(pair.time, pair.time + 1), confirmation: code) }
    }
    // The header stays pending and byte-identical through each independent graph mutation.
    try store.connection.run("INSERT INTO ax_probe_blobs(hash,bytes,created_ts) VALUES('invented-hash',393216,?)", [.integer(pair.time)])
    let mutations: [() throws -> Void] = [
      { try store.connection.run("INSERT INTO ax_probe_refs(attempt_row,hash) VALUES(?,'invented-hash')", [.integer(row)]) },
      { try store.connection.run("INSERT INTO ax_probe_parts(attempt_row,ordinal,hash) VALUES(?,0,'invented-hash')", [.integer(row)]) },
      { try store.connection.transaction {
        for ordinal in 0..<6 {
          try store.connection.run("INSERT INTO ax_probe_chunks(hash,ordinal,text) VALUES('invented-hash',?,?)",
            [.integer(ordinal), .maskedText(String(repeating: "x", count: AXProbeResources.chunkBytes))])
        }
      } },
      { try store.connection.run("UPDATE ax_probe_blobs SET complete=1 WHERE hash='invented-hash'") },
    ]
    for mutate in mutations {
      let before = try preview()
      try mutate()
      XCTAssertEqual(try probeContentSnapshot(store)["ax_probe_attempts"], header)
      XCTAssertNotEqual(try preview().confirmation, before.confirmation)
      XCTAssertThrowsError(try remove(before.confirmation)) { error in
        XCTAssertTrue(String(describing: error).contains("request a new preview"))
      }
    }
    try remove(preview().confirmation)
    for table in ["ax_probe_parts", "ax_probe_refs", "ax_probe_blobs", "ax_probe_chunks"] {
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table)"), 0)
    }
  }
  func testAXProbeRangePreviewDetectsRefsPartsChunksAndBlobChangesWithUnchangedPendingHeader() throws {
    try verifyProbeGraphPreviewFreshness(runForget: false)
  }
  func testAXProbeRunPreviewDetectsRefsPartsChunksAndBlobChangesWithUnchangedPendingHeader() throws {
    try verifyProbeGraphPreviewFreshness(runForget: true)
  }
  func testAXProbeBusyPersistenceFailureReceiptRetriesTerminalStatusAndCounterExactlyOnce() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    var pair = try resourcePair(store); pair.ax.status = .pending
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    pair.ax.status = .completed
    pair.ax.nodes = [AXProbeNode(nodeID: 1, attributes: [AXProbeText(attribute: "AXValue", text: "Invented failed payload")])]
    let writer = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let failed = expectation(description: "failure receipt retained during busy writer")
    let pipeline = AXProbePipeline(write: { pair, evidence, now, gate in
      _ = try store.appendAXProbe(pair, evidenceID: evidence, at: now, permitted: gate)
    }, dropped: { _ in XCTFail("unexpected overload") }, failed: { receipt in
      do {
        try store.recordAXProbePersistenceFailure(receipt)
        XCTFail("writer lock must keep the receipt pending")
      } catch {}
      failed.fulfill()
    })
    let receipt = try XCTUnwrap(pipeline.offer(pair, permitted: { true }))
    try writer.connection.transaction {
      pipeline.commit(receipt, evidenceID: nil, at: pair.time)
      wait(for: [failed], timeout: 10)
      XCTAssertThrowsError(try store.retryAXProbeFinishes())
      XCTAssertEqual(store.axProbePersistenceFailures.count, 1)
    }
    try store.retryAXProbeFinishes(); try store.retryAXProbeFinishes()
    let done = expectation(description: "raw payload released")
    pipeline.drain { done.fulfill() }; wait(for: [done], timeout: 5)
    XCTAssertEqual(pipeline.reservedBytes, 0)
    XCTAssertTrue(store.axProbePersistenceFailures.isEmpty)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='storage_failed'"), 1)
    for table in ["ax_probe_parts", "ax_probe_refs", "ax_probe_blobs", "ax_probe_chunks"] {
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table)"), 0)
    }
  }
  func testAXProbeBusyOverloadReceiptRetriesExactlyOnce() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    var pair = try resourcePair(store); pair.ax.status = .pending
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    let other = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try other.connection.transaction {
      XCTAssertThrowsError(try store.countAXProbeOverload(AXProbeReceipt(pair)))
    }
    try store.retryAXProbeFinishes(); try store.retryAXProbeFinishes()
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='overload_dropped'"), 1)
    XCTAssertTrue(try store.axProbeStatus().contains("overload_dropped=1"))
  }
  func testAXProbeOverloadIsCountedAndShownInStatus() throws {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var pair = try resourcePair(store); pair.ax = AXProbeResult(status: .pending)
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    let pipeline = AXProbePipeline(capacity: 1, write: { _, _, _, _ in XCTFail("full queue must not prepare payload") }, dropped: { receipt in try? store.countAXProbeOverload(receipt) })
    XCTAssertNil(pipeline.offer(pair, permitted: { true }))
    let done = expectation(description: "drop counted")
    pipeline.drain { done.fulfill() }; wait(for: [done], timeout: 5)
    let status = try store.axProbeStatus()
    XCTAssertTrue(status.contains("overload_dropped=1")); XCTAssertTrue(status.contains("ax_probe_storage_bytes=")); XCTAssertTrue(status.contains("ax_probe_added_24h_bytes="))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='overload_dropped'"), 1)
  }
}
